import jwt from "jsonwebtoken"

export const JWT_SECRET = process.env.JWT_SECRET ?? "nasx-dev-secret"

export interface TokenPayload {
  userId: string
  isAdmin: boolean
  canManageUsers: boolean
}

export function signToken(userId: string, isAdmin: boolean, canManageUsers: boolean): string {
  return jwt.sign({ userId, isAdmin, canManageUsers }, JWT_SECRET, { expiresIn: "7d" })
}

export function verifyToken(token: string): TokenPayload {
  return jwt.verify(token, JWT_SECRET) as TokenPayload
}

/**
 * Glob-style permission matching.
 * Supported wildcards: `*.*` (all), `ns.*` (all actions in namespace).
 * Example: hasPermission(["users.*"], "users.manage") === true
 */
export function hasPermission(grants: string[], required: string): boolean {
  const [reqNs] = required.split(".")
  return grants.some(g => {
    if (g === required) return true
    if (g === "*.*") return true
    const [ns, action] = g.split(".")
    if (ns === reqNs && action === "*") return true
    return false
  })
}
