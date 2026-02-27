import { FastifyInstance } from "fastify"
import { isNatsConnected } from "../nats"

export async function healthRoutes(app: FastifyInstance) {
  app.get("/health", async (_req, reply) => {
    const nats = isNatsConnected()
    if (!nats) {
      return reply.status(503).send({ status: "degraded", nats: false })
    }
    return { status: "ok", nats: true }
  })
}
