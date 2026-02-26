import { TRPCError } from "@trpc/server"
import { z } from "zod"
import bcrypt from "bcryptjs"
import { router, publicProcedure } from "../index"
import { signToken, hasPermission } from "../auth"

export const authRouter = router({
  login: publicProcedure
    .input(z.object({
      username: z.string().min(1).max(64),
      password: z.string().min(1).max(128),
    }))
    .mutation(async ({ ctx, input }) => {
      const user = await ctx.prisma.user.findUnique({
        where: { username: input.username },
        select: {
          id: true,
          password: true,
          userRoles: {
            select: {
              role: {
                select: {
                  isAdmin: true,
                  permissions: { select: { permission: { select: { name: true } } } },
                },
              },
            },
          },
        },
      })

      if (!user || !(await bcrypt.compare(input.password, user.password))) {
        throw new TRPCError({ code: "UNAUTHORIZED", message: "Invalid credentials" })
      }

      const isAdmin = user.userRoles.some(ur => ur.role.isAdmin)
      const allPerms = user.userRoles.flatMap(ur =>
        ur.role.permissions.map(rp => rp.permission.name)
      )
      const canManageUsers = isAdmin || hasPermission(allPerms, "users.manage")

      return { token: signToken(user.id, isAdmin, canManageUsers) }
    }),
})
