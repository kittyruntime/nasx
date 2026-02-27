import { z } from "zod"
import { router, publicProcedure, protectedProcedure } from "../index"
import { blacklistToken } from "../auth"
import { loginUser } from "../../services/auth.service"

export const authRouter = router({
  login: publicProcedure
    .input(z.object({
      username: z.string().min(1).max(64),
      password: z.string().min(1).max(128),
    }))
    .mutation(({ ctx, input }) => loginUser(ctx.prisma, input.username, input.password)),

  logout: protectedProcedure
    .mutation(({ ctx }) => {
      blacklistToken(ctx.user.jti)
      return { ok: true }
    }),
})
