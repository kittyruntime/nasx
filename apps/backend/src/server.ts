import { buildApp, connectNats, startEventSubscriber } from "./app"

const app = buildApp()

const start = async () => {
  try {
    await connectNats()
    void startEventSubscriber(app.log).catch(err => {
      app.log.error(err, "nats: event subscriber fatal error")
      process.exit(1)
    })

    await app.listen({ port: 9001, host: "0.0.0.0" })
  } catch (err) {
    app.log.error(err)
    process.exit(1)
  }
}

start()
