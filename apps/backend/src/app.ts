import Fastify from "fastify"
import cors from "@fastify/cors"
import { fastifyTRPCPlugin } from "@trpc/server/adapters/fastify"

import { healthRoutes } from "./routes/health"
import { fileRoutes } from "./routes/files"
import { appRouter } from "./trpc/routers/index"
import { createContext } from "./trpc/context"

export function buildApp() {
    const app = Fastify({
        logger: true,
        bodyLimit: 50 * 1024 * 1024, // 50 MB — covers 2 MB chunks with headroom
    })

    app.register(cors)

    app.register(healthRoutes)
    app.register(fileRoutes)

    app.register(fastifyTRPCPlugin, {
        prefix: "/trpc",
        trpcOptions: {
            router: appRouter,
            createContext,
        },
    })

    return app
}
