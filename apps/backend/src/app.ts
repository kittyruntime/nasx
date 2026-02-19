import path from "node:path"
import { fileURLToPath } from "node:url"
import Fastify from "fastify"
import cors from "@fastify/cors"
import fastifyStatic from "@fastify/static"
import { fastifyTRPCPlugin } from "@trpc/server/adapters/fastify"

import { healthRoutes } from "./routes/health"
import { fileRoutes } from "./routes/files"
import { appRouter } from "./trpc/routers/index"
import { createContext } from "./trpc/context"
export { connectNats, startEventSubscriber } from "./nats"

// Resolve dashboard dist: configurable via env (supports relative paths resolved from CWD),
// defaults to public/ next to server.js in the production layout.
const DASHBOARD_DIR = process.env.DASHBOARD_PATH
    ? path.resolve(process.env.DASHBOARD_PATH)
    : path.resolve(path.dirname(fileURLToPath(import.meta.url)), "public")

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

    // Serve the dashboard SPA — registered last so API routes take priority.
    // wildcard: true (default) registers GET /* which serves existing files and
    // calls reply.callNotFound() for missing ones, triggering the handler below.
    app.register(fastifyStatic, {
        root: DASHBOARD_DIR,
    })

    // SPA fallback: unknown routes → index.html (client-side routing)
    app.setNotFoundHandler((_req, reply) => {
        reply.sendFile("index.html")
    })

    return app
}
