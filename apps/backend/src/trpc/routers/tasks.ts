import { z } from "zod"
import { TRPCError } from "@trpc/server"
import { router, protectedProcedure } from "../index"

export const tasksRouter = router({
  get: protectedProcedure
    .input(z.object({ jobId: z.string().uuid() }))
    .query(async ({ ctx, input }) => {
      const job = await ctx.prisma.job.findUnique({ where: { id: input.jobId } })
      if (!job) throw new TRPCError({ code: "NOT_FOUND", message: "Job not found" })
      return {
        id:     job.id,
        status: job.status as "pending" | "running" | "completed" | "failed",
        action: job.action,
        result: job.result ? JSON.parse(job.result) : null,
        error:  job.error ?? null,
      }
    }),
})
