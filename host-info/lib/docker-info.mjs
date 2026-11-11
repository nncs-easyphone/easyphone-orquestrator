import http from 'node:http'

// Socket Unix exposto pelo docker-proxy. O host-info nunca vê o socket real.
const DOCKER_SOCKET = '/run/docker-proxy/docker.sock'
const DEFAULT_PROJECT = 'easyphone'
const MAX_ITEMS = 100

function dockerRequest(path) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        socketPath: DOCKER_SOCKET,
        path,
        method: 'GET',
        timeout: 5_000,
      },
      (response) => {
        let body = ''

        response.setEncoding('utf8')
        response.on('data', (chunk) => {
          body += chunk
          if (body.length > 10_000_000) {
            request.destroy(new Error('resposta da API do Docker excedeu o limite'))
          }
        })
        response.on('end', () => {
          const status = response.statusCode ?? 0
          if (status < 200 || status >= 300) {
            reject(new Error(`Docker API ${status}: ${body.slice(0, 200)}`))
            return
          }
          resolve(body)
        })
      },
    )

    request.on('timeout', () => request.destroy(new Error('timeout na API do Docker')))
    request.on('error', reject)
    request.end()
  })
}

async function dockerJson(path) {
  const body = await dockerRequest(path)
  return JSON.parse(body)
}

function toIsoDate(seconds) {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return null
  return new Date(seconds * 1000).toISOString()
}

function safeString(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function splitRepositoryAndTag(repoTag) {
  if (!repoTag || repoTag.includes('<none>')) {
    return { repository: null, tag: null }
  }

  const lastColon = repoTag.lastIndexOf(':')
  const lastSlash = repoTag.lastIndexOf('/')

  if (lastColon > lastSlash) {
    return {
      repository: repoTag.slice(0, lastColon),
      tag: repoTag.slice(lastColon + 1),
    }
  }

  return { repository: repoTag, tag: null }
}

function containerName(container) {
  const name = Array.isArray(container.Names) ? container.Names[0] : null
  return name ? name.replace(/^\//, '') : null
}

async function containerHealth(prefix, containerId) {
  try {
    const details = await dockerJson(`${prefix}/containers/${containerId}/json`)
    const status = details?.State?.Health?.Status
    return typeof status === 'string' ? status : null
  } catch {
    return null
  }
}

/**
 * Coleta somente o projeto Compose da instalação. O Engine API é consultado
 * pelo socket unix; não há dependência de CLI do Docker dentro do container.
 */
export async function collectDockerInfo({ project = DEFAULT_PROJECT } = {}) {
  const version = await dockerJson('/version')
  const apiVersion = safeString(version?.ApiVersion)
  const prefix = apiVersion && /^\d+\.\d+$/.test(apiVersion) ? `/v${apiVersion}` : ''

  const containersPayload = await dockerJson(`${prefix}/containers/json?all=1`)
  const containers = Array.isArray(containersPayload) ? containersPayload : []
  const projectContainers = containers.filter(
    (container) => container?.Labels?.['com.docker.compose.project'] === project,
  )

  const imagesPayload = await dockerJson(`${prefix}/images/json?all=1`)
  const allImages = Array.isArray(imagesPayload) ? imagesPayload : []
  const imagesById = new Map(allImages.map((image) => [image.Id, image]))

  const healthByContainer = new Map(
    await Promise.all(
      projectContainers.map(async (container) => [
        container.Id,
        await containerHealth(prefix, container.Id),
      ]),
    ),
  )

  const imageIds = new Set()
  const containersResult = projectContainers.slice(0, MAX_ITEMS).map((container) => {
    if (container.ImageID) imageIds.add(container.ImageID)

    const image = imagesById.get(container.ImageID)
    const repoTag = Array.isArray(image?.RepoTags)
      ? image.RepoTags.find((tag) => typeof tag === 'string' && !tag.includes('<none>'))
      : null

    return {
      name: containerName(container),
      service: safeString(container.Labels?.['com.docker.compose.service']),
      image: safeString(container.Image) ?? repoTag,
      imageId: safeString(container.ImageID),
      state: safeString(container.State),
      status: safeString(container.Status),
      health: healthByContainer.get(container.Id) ?? null,
      createdAt: toIsoDate(container.Created),
    }
  })

  const servicesByImageId = new Map()
  for (const container of projectContainers) {
    if (!container.ImageID) continue
    const services = servicesByImageId.get(container.ImageID) ?? new Set()
    const service = safeString(container.Labels?.['com.docker.compose.service'])
    if (service) services.add(service)
    servicesByImageId.set(container.ImageID, services)
  }

  const imagesResult = [...imageIds]
    .map((imageId) => {
      const image = imagesById.get(imageId)
      if (!image) return null

      const repoTag = Array.isArray(image.RepoTags)
        ? image.RepoTags.find((tag) => typeof tag === 'string' && !tag.includes('<none>'))
        : null
      const { repository, tag } = splitRepositoryAndTag(repoTag)
      const digests = Array.isArray(image.RepoDigests)
        ? image.RepoDigests.filter((digest) => typeof digest === 'string')
        : []

      return {
        repository,
        tag,
        imageId: safeString(image.Id),
        digests,
        createdAt: toIsoDate(image.Created),
        sizeBytes: typeof image.Size === 'number' ? image.Size : null,
        services: [...(servicesByImageId.get(imageId) ?? [])].sort(),
      }
    })
    .filter(Boolean)
    .slice(0, MAX_ITEMS)

  return {
    available: true,
    engineVersion: safeString(version?.Version),
    apiVersion,
    composeProject: project,
    containers: containersResult,
    images: imagesResult,
    error: null,
  }
}
