import { createSign } from 'node:crypto'

const TOKEN_TTL_SECONDS = 300
const REQUEST_TIMEOUT_MS = 30_000
const REPORT_SCOPE = 'system:report'

function base64Url(value) {
  return Buffer.from(value).toString('base64url')
}

export function parseServiceAccount(rawValue) {
  if (!rawValue) throw new Error('FIREBASE_SERVICE_ACCOUNT vazio')

  const serviceAccount = JSON.parse(rawValue)
  if (
    typeof serviceAccount.private_key !== 'string'
    || typeof serviceAccount.client_email !== 'string'
    || typeof serviceAccount.private_key_id !== 'string'
  ) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT inválido')
  }

  serviceAccount.private_key = serviceAccount.private_key.replace(/\\n/g, '\n')
  return serviceAccount
}

export function createReportToken({
  serviceAccount,
  licenseClientId,
  hardwareId,
  now = Math.floor(Date.now() / 1000),
}) {
  const header = {
    alg: 'RS256',
    typ: 'JWT',
    kid: serviceAccount.private_key_id,
  }

  const payload = {
    iat: now,
    exp: now + TOKEN_TTL_SECONDS,
    aud: 'ivr-api-v1',
    scope: REPORT_SCOPE,
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    licenseClientId,
    hardwareId,
  }

  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`
  const signer = createSign('RSA-SHA256')
  signer.update(signingInput)
  signer.end()

  const signature = signer.sign(serviceAccount.private_key).toString('base64url')
  return `${signingInput}.${signature}`
}

export async function sendSystemReport({
  firebaseUrl,
  serviceAccount,
  licenseClientId,
  hardwareId,
  report,
}) {
  const baseUrl = firebaseUrl.replace(/\/+$/, '')
  const token = createReportToken({
    serviceAccount,
    licenseClientId,
    hardwareId,
  })

  const response = await fetch(`${baseUrl}/reportSystemHealth`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(report),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })

  if (!response.ok) {
    const body = await response.text()
    throw new Error(`reportSystemHealth ${response.status}: ${body.slice(0, 200)}`)
  }

  return response.status
}
