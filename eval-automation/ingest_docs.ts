#!/usr/bin/env bun

import { sign } from "hono/jwt"
import { readFileSync, existsSync } from "fs"
import { join } from "path"

const TEST_USER_EMAIL = process.env.TEST_USER_EMAIL || "suraj.nagre@juspay.in"
const COLLECTION_ID = process.env.COLLECTION_ID || "cl_eval_xyne_search"
const API_BASE = process.env.API_BASE || "http://localhost:3000"

const accessTokenSecret = process.env.ACCESS_TOKEN_SECRET || ""
const refreshTokenSecret = process.env.REFRESH_TOKEN_SECRET || ""

const AccessTokenCookieName = "access-token"
const RefreshTokenCookieName = "refresh-token"

const generateTokens = async (
  email: string,
  role: string,
  workspaceId: string,
  forRefreshToken: boolean = false,
) => {
  const payload = forRefreshToken
    ? {
        sub: email,
        role: role,
        workspaceId,
        tokenType: "refresh",
        exp: Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
      }
    : {
        sub: email,
        role: role,
        workspaceId,
        tokenType: "access",
        exp: Math.floor(Date.now() / 1000) + 15 * 60,
      }
  const jwtToken = await sign(
    payload,
    forRefreshToken ? refreshTokenSecret : accessTokenSecret,
  )
  return jwtToken
}

const generateAuthenticationCookies = async () => {
  const accessToken = await generateTokens(TEST_USER_EMAIL, "admin", "ws_default")
  const refreshToken = await generateTokens(TEST_USER_EMAIL, "admin", "ws_default", true)
  return { accessToken, refreshToken }
}

const uploadFile = async (filePath: string, cookies: { accessToken: string; refreshToken: string }) => {
  const fileName = filePath.split("/").pop() || "unknown"
  
  const formData = new FormData()
  const fileBuffer = readFileSync(filePath)
  const blob = new Blob([fileBuffer])
  const file = new File([blob], fileName)
  formData.append("files", file)
  formData.append("useOCR", "true")
  formData.append("duplicateStrategy", "rename")

  try {
    const response = await fetch(`${API_BASE}/api/v1/cl/${COLLECTION_ID}/items/upload`, {
      method: "POST",
      headers: {
        "Cookie": `${AccessTokenCookieName}=${cookies.accessToken}; ${RefreshTokenCookieName}=${cookies.refreshToken}`,
      },
      body: formData,
    })

    if (!response.ok) {
      const error = await response.text()
      throw new Error(`Upload failed: ${response.status} - ${error}`)
    }

    return await response.json()
  } catch (error) {
    throw error
  }
}

const main = async () => {
  const docsDir = process.env.DOCS_DIR || "./docs"
  
  if (!existsSync(docsDir)) {
    console.error(`Docs directory not found: ${docsDir}`)
    process.exit(1)
  }

  const fileList: string[] = []
  
  const { readdirSync } = await import('fs')
  for (const entry of readdirSync(docsDir)) {
    const fullPath = join(docsDir, entry)
    const stat = await import('fs').then(fs => fs.statSync(fullPath))
    if (stat.isFile() && !entry.startsWith(".")) {
      fileList.push(fullPath)
    }
  }

  if (fileList.length === 0) {
    console.log("No files found to ingest")
    return
  }

  console.log(`Found ${fileList.length} files to ingest`)
  
  const cookies = await generateAuthenticationCookies()
  
  let successCount = 0
  let failCount = 0

  for (let i = 0; i < fileList.length; i++) {
    const filePath = fileList[i]
    const fileName = filePath.split("/").pop()
    
    process.stdout.write(`[${i + 1}/${fileList.length}] Uploading: ${fileName}... `)
    
    try {
      await uploadFile(filePath, cookies)
      console.log("✓")
      successCount++
    } catch (error) {
      console.log(`✗ - ${error.message}`)
      failCount++
    }
    
    await new Promise(resolve => setTimeout(resolve, 500))
  }

  console.log(`\n==========================================`)
  console.log(`Ingestion complete: ${successCount} succeeded, ${failCount} failed`)
  console.log(`==========================================`)
}

main().catch(console.error)
