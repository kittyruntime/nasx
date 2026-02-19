import { router } from "../index"
import { authRouter } from "./auth"
import { userRouter } from "./user"
import { placeRouter } from "./place"
import { fsRouter } from "./fs"
import { roleRouter } from "./role"
import { permissionRouter } from "./permission"

export const appRouter = router({
  auth: authRouter,
  user: userRouter,
  place: placeRouter,
  fs: fsRouter,
  role: roleRouter,
  permission: permissionRouter,
})

export type AppRouter = typeof appRouter
