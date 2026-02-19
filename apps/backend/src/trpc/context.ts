import { prisma } from "@nasx/database"
import type { CreateFastifyContextOptions } from "@trpc/server/adapters/fastify"
import { verifyToken, type TokenPayload } from "./auth"

export function createContext({ req, res }: CreateFastifyContextOptions) {
  let user: TokenPayload | null = null

  const authHeader = req.headers.authorization
  if (authHeader?.startsWith("Bearer ")) {
    try {
      user = verifyToken(authHeader.slice(7))
    } catch {
      // invalid token — user stays null
    }
  }

  return { prisma, req, res, user }
}

export type Context = Awaited<ReturnType<typeof createContext>>
