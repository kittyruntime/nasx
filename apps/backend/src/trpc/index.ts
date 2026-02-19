import { TRPCError, initTRPC } from "@trpc/server"
import type { Context } from "./context"

const t = initTRPC.context<Context>().create()

export const router = t.router
export const publicProcedure = t.procedure

const isAuthed = t.middleware(({ ctx, next }) => {
  if (!ctx.user) {
    throw new TRPCError({ code: "UNAUTHORIZED" })
  }
  return next({ ctx: { user: ctx.user } })
})

const isAdmin = t.middleware(({ ctx, next }) => {
  if (!ctx.user?.isAdmin) {
    throw new TRPCError({ code: "FORBIDDEN" })
  }
  return next()
})

const isUserManager = t.middleware(({ ctx, next }) => {
  if (!ctx.user?.isAdmin && !ctx.user?.canManageUsers) {
    throw new TRPCError({ code: "FORBIDDEN" })
  }
  return next()
})

export const protectedProcedure = t.procedure.use(isAuthed)
export const adminProcedure = t.procedure.use(isAuthed).use(isAdmin)
export const userManagerProcedure = t.procedure.use(isAuthed).use(isUserManager)
