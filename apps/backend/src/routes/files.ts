import type { FastifyInstance } from "fastify"
import { createReadStream } from "node:fs"
import { stat } from "node:fs/promises"
import { join, basename, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"
import { verifyToken } from "../trpc/auth"
import { prisma } from "@nasx/database"

const FS_HELPER = process.env.FS_HELPER_PATH
  ?? resolve(fileURLToPath(new URL("../../bin/fs-helper", import.meta.url)))

// ── shared helpers ────────────────────────────────────────────────────────────

async function hasPermission(
  userId: string,
  isAdmin: boolean,
  path: string,
  flag: "canRead" | "canWrite",
): Promise<boolean> {
  if (isAdmin) return true
  const places = await prisma.place.findMany()
  const place  = places.find(p => path === p.path || path.startsWith(p.path + "/"))
  if (!place) return false
  const roleIds = (
    await prisma.userRole.findMany({ where: { userId }, select: { roleId: true } })
  ).map(r => r.roleId)
  const [u, r] = await Promise.all([
    prisma.userPlacePermission.findFirst({ where: { userId, placeId: place.id, [flag]: true } }),
    roleIds.length
      ? prisma.rolePlacePermission.findFirst({ where: { roleId: { in: roleIds }, placeId: place.id, [flag]: true } })
      : null,
  ])
  return !!(u || r)
}

async function getLinuxUser(userId: string): Promise<string | null> {
  const u = await prisma.user.findUnique({ where: { id: userId }, select: { linuxUsername: true } })
  return u?.linuxUsername ?? null
}

function runFsHelper(
  args: string[],
  linuxUser: string | null,
  opts: { maxBuffer?: number; input?: Buffer } = {},
) {
  const { maxBuffer = 2 * 1024 * 1024 * 1024, input } = opts
  const [cmd, cmdArgs]: [string, string[]] = linuxUser
    ? ["sudo", ["-u", linuxUser, FS_HELPER, ...args]]
    : [FS_HELPER, args]
  return spawnSync(cmd, cmdArgs, { encoding: "buffer", timeout: 300_000, maxBuffer, input })
}

function authFromRequest(req: { headers: { authorization?: string } }) {
  const h = req.headers.authorization
  if (!h?.startsWith("Bearer ")) return null
  try { return verifyToken(h.slice(7)) } catch { return null }
}

// ── in-memory upload state ────────────────────────────────────────────────────

interface UploadState {
  received: Set<number>
  totalChunks: number
  fileName: string
  destDir: string
  stagingDir: string
  linuxUser: string | null
}

const uploadState = new Map<string, UploadState>()

// ── routes ────────────────────────────────────────────────────────────────────

export async function fileRoutes(app: FastifyInstance) {
  // Accept raw binary bodies for chunk uploads
  app.addContentTypeParser(
    "application/octet-stream",
    { parseAs: "buffer" },
    (_req, body, done) => done(null, body),
  )

  // ── GET /files/download?path=<path>&token=<jwt> ───────────────────────────
  app.get("/files/download", async (req, reply) => {
    const { path: filePath, token } = req.query as Record<string, string>
    if (!token || !filePath) return reply.status(400).send("Missing params")

    let user: { userId: string; isAdmin: boolean }
    try { user = verifyToken(token) }
    catch { return reply.status(401).send("Unauthorized") }

    if (!await hasPermission(user.userId, user.isAdmin, filePath, "canRead"))
      return reply.status(403).send("Forbidden")

    let fileSize: number
    try {
      const s = await stat(filePath)
      if (!s.isFile()) return reply.status(400).send("Not a file")
      fileSize = s.size
    } catch {
      return reply.status(404).send("Not found")
    }

    const name = basename(filePath)
    reply.header("Content-Disposition", `attachment; filename*=UTF-8''${encodeURIComponent(name)}`)
    reply.header("Content-Type", "application/octet-stream")

    const linuxUser = await getLinuxUser(user.userId)
    if (linuxUser) {
      const r = runFsHelper(["read", filePath], linuxUser)
      if (r.status !== 0) {
        if (r.status === 13) return reply.status(403).send("Permission denied")
        if (r.status === 2)  return reply.status(404).send("Not found")
        return reply.status(500).send(r.stderr?.toString().trim() || "Read failed")
      }
      reply.header("Content-Length", String(r.stdout.length))
      return reply.send(r.stdout)
    }

    reply.header("Content-Length", String(fileSize))
    return reply.send(createReadStream(filePath))
  })

  // ── POST /files/upload/chunk ──────────────────────────────────────────────
  //
  // Headers:
  //   X-Upload-Id      — unique ID per file upload (UUID)
  //   X-Chunk-Index    — 0-based chunk index
  //   X-Total-Chunks   — total number of chunks for this file
  //   X-File-Name      — URI-encoded original filename
  //   X-Dest-Dir       — URI-encoded destination directory path
  //
  // Body: raw binary chunk (application/octet-stream)
  //
  // Chunks are written directly into <destDir>/.nasx-uploads-<uploadId>/
  // via fs-helper running as the linuxUser — no /tmp involved.
  app.post("/files/upload/chunk", async (req, reply) => {
    const user = authFromRequest(req)
    if (!user) return reply.status(401).send("Unauthorized")

    const uploadId    = req.headers["x-upload-id"]    as string
    const chunkIndex  = parseInt(req.headers["x-chunk-index"]  as string, 10)
    const totalChunks = parseInt(req.headers["x-total-chunks"] as string, 10)
    const fileName    = decodeURIComponent(req.headers["x-file-name"] as string ?? "")
    const destDir     = decodeURIComponent(req.headers["x-dest-dir"]  as string ?? "")

    if (!uploadId || isNaN(chunkIndex) || isNaN(totalChunks) || !fileName || !destDir)
      return reply.status(400).send("Missing upload metadata")

    if (!await hasPermission(user.userId, user.isAdmin, destDir, "canWrite"))
      return reply.status(403).send("Forbidden")

    // Init state and create staging dir on first chunk
    let state = uploadState.get(uploadId)
    if (!state) {
      const linuxUser = await getLinuxUser(user.userId)
      const stagingDir = join(destDir, `.nasx-uploads-${uploadId}`)
      const mk = runFsHelper(["mkdirp", stagingDir], linuxUser, { maxBuffer: 64 * 1024 })
      if (mk.status !== 0)
        return reply.status(500).send(mk.stderr?.toString().trim() || "Failed to create staging dir")
      state = { received: new Set(), totalChunks, fileName, destDir, stagingDir, linuxUser }
      uploadState.set(uploadId, state)
    }

    // Write chunk directly into staging dir as linuxUser
    const chunkPath = join(state.stagingDir, `${chunkIndex}.part`)
    const wr = runFsHelper(["write-stdin", chunkPath], state.linuxUser, {
      input: req.body as Buffer,
      maxBuffer: 64 * 1024,
    })
    if (wr.status !== 0)
      return reply.status(500).send(wr.stderr?.toString().trim() || "Failed to write chunk")

    state.received.add(chunkIndex)
    if (state.received.size < totalChunks) return reply.send({ ok: true, done: false })

    // All chunks received — assemble into final file
    const partPaths = Array.from({ length: totalChunks }, (_, i) => join(state.stagingDir, `${i}.part`))
    const finalPath = join(destDir, fileName)
    const ar = runFsHelper(["assemble", finalPath, ...partPaths], state.linuxUser, { maxBuffer: 64 * 1024 })

    // Always clean up staging dir
    runFsHelper(["delete", state.stagingDir], state.linuxUser, { maxBuffer: 64 * 1024 })
    uploadState.delete(uploadId)

    if (ar.status !== 0) {
      if (ar.status === 13) return reply.status(403).send("Permission denied")
      return reply.status(500).send(ar.stderr?.toString().trim() || "Assembly failed")
    }

    return reply.send({ ok: true, done: true })
  })

  // ── DELETE /files/upload/cancel ───────────────────────────────────────────
  // Body: { uploadId: string }
  // Cleans up the staging directory for an in-progress upload.
  app.delete("/files/upload/cancel", async (req, reply) => {
    const user = authFromRequest(req)
    if (!user) return reply.status(401).send("Unauthorized")

    const { uploadId } = (req.body ?? {}) as { uploadId?: string }
    if (!uploadId) return reply.status(400).send("Missing uploadId")

    const state = uploadState.get(uploadId)
    if (!state) return reply.send({ ok: true }) // Already done or never existed

    runFsHelper(["delete", state.stagingDir], state.linuxUser, { maxBuffer: 64 * 1024 })
    uploadState.delete(uploadId)

    return reply.send({ ok: true })
  })
}
