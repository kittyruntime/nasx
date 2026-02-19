import { z } from "zod"
import { readdir, stat } from "node:fs/promises"
import { join, normalize, resolve } from "node:path"
import { spawnSync } from "node:child_process"
import { TRPCError } from "@trpc/server"
import { router, protectedProcedure, adminProcedure } from "../index"
import { accessiblePlaceIds } from "./place"

const FS_HELPER = resolve(new URL("../../../bin/fs-helper", import.meta.url).pathname)

// ── helper runner ────────────────────────────────────────────────────────────

type RunMode = "as-linux-user" | "as-root" | "as-process"

function runHelper(args: string[], mode: RunMode, linuxUser?: string | null): unknown {
  let cmd: string
  let cmdArgs: string[]

  if (mode === "as-root") {
    cmd = "sudo"; cmdArgs = [FS_HELPER, ...args]
  } else if (mode === "as-linux-user" && linuxUser) {
    cmd = "sudo"; cmdArgs = ["-u", linuxUser, FS_HELPER, ...args]
  } else {
    cmd = FS_HELPER; cmdArgs = args
  }

  const result = spawnSync(cmd, cmdArgs, { encoding: "utf8", timeout: 60_000 })

  if (result.error) throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: result.error.message })

  const stderr = result.stderr?.trim() ?? ""
  if (result.status === 13 || stderr === "EACCES") throw new TRPCError({ code: "FORBIDDEN",  message: "Permission denied" })
  if (result.status === 2  || stderr === "ENOENT")  throw new TRPCError({ code: "NOT_FOUND",  message: "Not found" })
  if (result.status === 17 || stderr === "EEXIST")  throw new TRPCError({ code: "CONFLICT",   message: "Destination already exists" })
  if (result.status !== 0) throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: stderr || "Unknown error" })

  return JSON.parse(result.stdout)
}

// ── shared helpers ────────────────────────────────────────────────────────────

async function getLinuxUser(ctx: { prisma: any; user: { userId: string } }): Promise<string | null> {
  const u = await ctx.prisma.user.findUnique({
    where: { id: ctx.user.userId },
    select: { linuxUsername: true },
  })
  return u?.linuxUsername ?? null
}

async function checkPathPerm(
  ctx: { prisma: any; user: { userId: string; isAdmin: boolean } },
  path: string,
  flag: "canRead" | "canWrite" | "canDelete"
): Promise<void> {
  if (ctx.user.isAdmin) return

  const places = await ctx.prisma.place.findMany()
  const place = places.find(
    (p: { path: string }) => path === p.path || path.startsWith(p.path + "/")
  )
  if (!place) throw new TRPCError({ code: "FORBIDDEN", message: "Access denied" })

  const userRoles = await ctx.prisma.userRole.findMany({
    where: { userId: ctx.user.userId }, select: { roleId: true },
  })
  const roleIds = userRoles.map((r: { roleId: string }) => r.roleId)

  const [userPerm, rolePerm] = await Promise.all([
    ctx.prisma.userPlacePermission.findFirst({
      where: { userId: ctx.user.userId, placeId: place.id, [flag]: true },
    }),
    roleIds.length > 0
      ? ctx.prisma.rolePlacePermission.findFirst({
          where: { roleId: { in: roleIds }, placeId: place.id, [flag]: true },
        })
      : null,
  ])

  if (!userPerm && !rolePerm) throw new TRPCError({ code: "FORBIDDEN", message: "Access denied" })
}

// ── list (original) ───────────────────────────────────────────────────────────

type FsEntry = { name: string; path: string; type: "dir" | "file"; size: number | null; mtime: string }

async function listAsProcess(dirPath: string): Promise<FsEntry[]> {
  const names = await readdir(dirPath)
  const entries = await Promise.all(
    names.map(async (name) => {
      const fullPath = join(dirPath, name)
      try {
        const s = await stat(fullPath)
        return { name, path: fullPath, type: s.isDirectory() ? ("dir" as const) : ("file" as const), size: s.isFile() ? s.size : null, mtime: s.mtime.toISOString() }
      } catch { return null }
    })
  )
  return entries.filter((e): e is FsEntry => e !== null)
}

function sortEntries(entries: FsEntry[]): FsEntry[] {
  return entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "dir" ? -1 : 1
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
  })
}

// ── router ────────────────────────────────────────────────────────────────────

export const fsRouter = router({

  list: protectedProcedure
    .input(z.object({ path: z.string() }))
    .query(async ({ ctx, input }) => {
      const p = normalize(input.path)
      if (!p.startsWith("/") || p.includes("\0")) throw new TRPCError({ code: "BAD_REQUEST", message: "Invalid path" })

      if (!ctx.user.isAdmin) {
        const ids = await accessiblePlaceIds(ctx)
        const places = await ctx.prisma.place.findMany({ where: { id: { in: ids } } })
        const allowed = places.some((pl: { path: string }) => p === pl.path || p.startsWith(pl.path + "/"))
        if (!allowed) throw new TRPCError({ code: "FORBIDDEN", message: "Access denied" })
      }

      const linuxUser = await getLinuxUser(ctx)
      try {
        const entries = linuxUser
          ? (runHelper(["list", p], "as-linux-user", linuxUser) as FsEntry[])
          : await listAsProcess(p)
        return sortEntries(entries)
      } catch (e: any) {
        if (e instanceof TRPCError) throw e
        if (e.code === "EACCES") throw new TRPCError({ code: "FORBIDDEN",  message: "Permission denied" })
        if (e.code === "ENOENT")  throw new TRPCError({ code: "NOT_FOUND",  message: "Directory not found" })
        throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: e.message })
      }
    }),

  mkdir: protectedProcedure
    .input(z.object({ parentPath: z.string(), name: z.string().min(1).max(255) }))
    .mutation(async ({ ctx, input }) => {
      const parent = normalize(input.parentPath)
      await checkPathPerm(ctx, parent, "canWrite")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["mkdir", parent, input.name], "as-linux-user", linuxUser)
    }),

  copy: protectedProcedure
    .input(z.object({ src: z.string(), dstDir: z.string() }))
    .mutation(async ({ ctx, input }) => {
      const src    = normalize(input.src)
      const dstDir = normalize(input.dstDir)
      await checkPathPerm(ctx, src,    "canRead")
      await checkPathPerm(ctx, dstDir, "canWrite")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["copy", src, dstDir], "as-linux-user", linuxUser)
    }),

  move: protectedProcedure
    .input(z.object({ src: z.string(), dstDir: z.string() }))
    .mutation(async ({ ctx, input }) => {
      const src    = normalize(input.src)
      const dstDir = normalize(input.dstDir)
      await checkPathPerm(ctx, src,    "canWrite")
      await checkPathPerm(ctx, dstDir, "canWrite")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["move", src, dstDir], "as-linux-user", linuxUser)
    }),

  rename: protectedProcedure
    .input(z.object({ path: z.string(), newName: z.string().min(1).max(255) }))
    .mutation(async ({ ctx, input }) => {
      const p = normalize(input.path)
      if (input.newName.includes("/") || input.newName === "." || input.newName === "..") {
        throw new TRPCError({ code: "BAD_REQUEST", message: "Invalid name" })
      }
      await checkPathPerm(ctx, p, "canWrite")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["rename", p, input.newName], "as-linux-user", linuxUser)
    }),

  delete: protectedProcedure
    .input(z.object({ path: z.string() }))
    .mutation(async ({ ctx, input }) => {
      const p = normalize(input.path)
      await checkPathPerm(ctx, p, "canDelete")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["delete", p], "as-linux-user", linuxUser)
    }),

  stat: protectedProcedure
    .input(z.object({ path: z.string() }))
    .query(async ({ ctx, input }) => {
      const p = normalize(input.path)
      await checkPathPerm(ctx, p, "canRead")
      const linuxUser = await getLinuxUser(ctx)
      return runHelper(["stat", p], "as-linux-user", linuxUser) as {
        mode: string; owner: string; group: string; uid: number; gid: number; type: string; size: number | null
      }
    }),

  chmod: adminProcedure
    .input(z.object({ path: z.string(), mode: z.string().regex(/^[0-7]{3,4}$/) }))
    .mutation(({ ctx: _ctx, input }) => {
      return runHelper(["chmod", input.mode, normalize(input.path)], "as-root")
    }),

  chown: adminProcedure
    .input(z.object({ path: z.string(), owner: z.string().min(1), group: z.string().min(1) }))
    .mutation(({ ctx: _ctx, input }) => {
      return runHelper(["chown", input.owner, input.group, normalize(input.path)], "as-root")
    }),
})
