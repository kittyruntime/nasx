import { z } from "zod"
import { router, adminProcedure } from "../index"

const SubjectType = z.enum(["user", "role"])

export const permissionRouter = router({
  /** Returns all permissions for a place, normalised to a common shape. */
  listForPlace: adminProcedure
    .input(z.object({ placeId: z.string() }))
    .query(async ({ ctx, input }) => {
      const [rolePerms, userPerms] = await Promise.all([
        ctx.prisma.rolePlacePermission.findMany({ where: { placeId: input.placeId } }),
        ctx.prisma.userPlacePermission.findMany({ where: { placeId: input.placeId } }),
      ])
      return [
        ...rolePerms.map((p) => ({ ...p, subjectType: "role" as const, subjectId: p.roleId })),
        ...userPerms.map((p) => ({ ...p, subjectType: "user" as const, subjectId: p.userId })),
      ]
    }),

  /** Create or update a permission record. */
  upsert: adminProcedure
    .input(
      z.object({
        placeId: z.string(),
        subjectType: SubjectType,
        subjectId: z.string(),
        canRead: z.boolean(),
        canWrite: z.boolean(),
        canDelete: z.boolean(),
      })
    )
    .mutation(async ({ ctx, input }) => {
      if (input.subjectType === "role") {
        return ctx.prisma.rolePlacePermission.upsert({
          where: { roleId_placeId: { roleId: input.subjectId, placeId: input.placeId } },
          update: { canRead: input.canRead, canWrite: input.canWrite, canDelete: input.canDelete },
          create: {
            roleId: input.subjectId,
            placeId: input.placeId,
            canRead: input.canRead,
            canWrite: input.canWrite,
            canDelete: input.canDelete,
          },
        })
      }
      return ctx.prisma.userPlacePermission.upsert({
        where: { userId_placeId: { userId: input.subjectId, placeId: input.placeId } },
        update: { canRead: input.canRead, canWrite: input.canWrite, canDelete: input.canDelete },
        create: {
          userId: input.subjectId,
          placeId: input.placeId,
          canRead: input.canRead,
          canWrite: input.canWrite,
          canDelete: input.canDelete,
        },
      })
    }),

  /** Remove a permission record. */
  remove: adminProcedure
    .input(
      z.object({
        placeId: z.string(),
        subjectType: SubjectType,
        subjectId: z.string(),
      })
    )
    .mutation(({ ctx, input }) => {
      if (input.subjectType === "role") {
        return ctx.prisma.rolePlacePermission.deleteMany({
          where: { roleId: input.subjectId, placeId: input.placeId },
        })
      }
      return ctx.prisma.userPlacePermission.deleteMany({
        where: { userId: input.subjectId, placeId: input.placeId },
      })
    }),
})
