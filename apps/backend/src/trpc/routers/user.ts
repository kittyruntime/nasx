import { z } from "zod"
import { TRPCError } from "@trpc/server"
import bcrypt from "bcryptjs"
import { router, protectedProcedure, userManagerProcedure } from "../index"

const userSelect = {
  id: true,
  username: true,
  displayName: true,
  linuxUsername: true,
  createdAt: true,
  userRoles: {
    select: {
      role: {
        select: {
          id: true,
          name: true,
          isAdmin: true,
          permissions: { select: { permission: { select: { name: true } } } },
        },
      },
    },
  },
} as const

export const userRouter = router({
  list: protectedProcedure.query(({ ctx }) => {
    return ctx.prisma.user.findMany({ select: userSelect, orderBy: { createdAt: "asc" } })
  }),

  me: protectedProcedure.query(({ ctx }) => {
    return ctx.prisma.user.findUniqueOrThrow({
      where: { id: ctx.user.userId },
      select: userSelect,
    })
  }),

  create: userManagerProcedure
    .input(z.object({
      username: z.string().min(1).max(64),
      password: z.string().min(6),
      displayName: z.string().max(64).optional(),
    }))
    .mutation(async ({ ctx, input }) => {
      const existing = await ctx.prisma.user.findUnique({ where: { username: input.username } })
      if (existing) throw new TRPCError({ code: "CONFLICT", message: "Username already taken" })

      const hashedPassword = await bcrypt.hash(input.password, 12)

      // Create user + personal role in one transaction
      return ctx.prisma.$transaction(async tx => {
        const user = await tx.user.create({
          data: {
            username: input.username,
            password: hashedPassword,
            displayName: input.displayName ?? null,
          },
          select: userSelect,
        })
        // Personal role: named after the username, assigned immediately
        const personalRole = await tx.role.create({ data: { name: input.username } })
        await tx.userRole.create({ data: { userId: user.id, roleId: personalRole.id } })
        // Re-fetch with the new role included
        return tx.user.findUniqueOrThrow({ where: { id: user.id }, select: userSelect })
      })
    }),

  update: userManagerProcedure
    .input(z.object({
      userId: z.string(),
      displayName: z.string().max(64).nullable().optional(),
      linuxUsername: z.string().max(64).nullable().optional(),
    }))
    .mutation(async ({ ctx, input }) => {
      const target = await ctx.prisma.user.findUnique({ where: { id: input.userId } })
      if (!target) throw new TRPCError({ code: "NOT_FOUND" })
      const targetIsAdmin = (await ctx.prisma.userRole.findMany({
        where: { userId: input.userId },
        include: { role: { select: { isAdmin: true } } },
      })).some(ur => ur.role.isAdmin)
      if (targetIsAdmin && !ctx.user.isAdmin)
        throw new TRPCError({ code: "FORBIDDEN", message: "Cannot edit admin users" })
      return ctx.prisma.user.update({
        where: { id: input.userId },
        data: {
          ...(input.displayName  !== undefined && { displayName:  input.displayName }),
          ...(input.linuxUsername !== undefined && { linuxUsername: input.linuxUsername }),
        },
        select: userSelect,
      })
    }),

  updateSelf: protectedProcedure
    .input(z.object({
      displayName: z.string().max(64).nullable().optional(),
    }))
    .mutation(({ ctx, input }) => {
      return ctx.prisma.user.update({
        where: { id: ctx.user.userId },
        data: { ...(input.displayName !== undefined && { displayName: input.displayName }) },
        select: userSelect,
      })
    }),

  changePassword: protectedProcedure
    .input(z.object({
      currentPassword: z.string(),
      newPassword: z.string().min(6),
    }))
    .mutation(async ({ ctx, input }) => {
      const user = await ctx.prisma.user.findUniqueOrThrow({
        where: { id: ctx.user.userId },
        select: { password: true },
      })
      if (!(await bcrypt.compare(input.currentPassword, user.password)))
        throw new TRPCError({ code: "FORBIDDEN", message: "Current password is incorrect" })
      const newHashed = await bcrypt.hash(input.newPassword, 12)
      return ctx.prisma.user.update({
        where: { id: ctx.user.userId },
        data: { password: newHashed },
        select: { id: true, username: true },
      })
    }),

  delete: userManagerProcedure
    .input(z.object({ userId: z.string() }))
    .mutation(async ({ ctx, input }) => {
      if (input.userId === ctx.user.userId)
        throw new TRPCError({ code: "FORBIDDEN", message: "You cannot delete your own account" })
      const target = await ctx.prisma.user.findUnique({ where: { id: input.userId } })
      if (!target) throw new TRPCError({ code: "NOT_FOUND" })
      const targetIsAdmin = (await ctx.prisma.userRole.findMany({
        where: { userId: input.userId },
        include: { role: { select: { isAdmin: true } } },
      })).some(ur => ur.role.isAdmin)
      if (targetIsAdmin && !ctx.user.isAdmin)
        throw new TRPCError({ code: "FORBIDDEN", message: "Cannot delete admin users" })
      return ctx.prisma.user.delete({ where: { id: input.userId } })
    }),
})
