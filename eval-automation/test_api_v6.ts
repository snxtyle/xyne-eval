#!/usr/bin/env bun

import { sign } from "hono/jwt"
import { db } from "../../server/db/client"
import { getUserByEmail } from "../../server/db/user"
import config from "../../server/config"
import { readFileSync, writeFileSync, existsSync } from "fs"
import { join } from "path"

// Use environment variable for test user email, or default to a test email
const TEST_USER_EMAIL = process.env.TEST_USER_EMAIL || "suraj.nagre@juspay.in"

const accessTokenSecret = process.env.ACCESS_TOKEN_SECRET!
const refreshTokenSecret = process.env.REFRESH_TOKEN_SECRET!

const AccessTokenCookieName = "access-token"
const RefreshTokenCookieName = "refresh-token"

// Configuration constants

/**
 * Generate JWT tokens programmatically (same logic as server.ts)
 */
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
        exp: Math.floor(Date.now() / 1000) + config.RefreshTokenTTL,
      }
    : {
        sub: email,
        role: role,
        workspaceId,
        tokenType: "access",
        exp: Math.floor(Date.now() / 1000) + config.AccessTokenTTL,
      }
  const jwtToken = await sign(
    payload,
    forRefreshToken ? refreshTokenSecret : accessTokenSecret,
  )
  return jwtToken
}

/**
 * Generate authentication cookies programmatically by creating JWT tokens
 */
async function generateAuthenticationCookies() {
  console.log(`Generating authentication tokens for user: ${TEST_USER_EMAIL}`)

  try {
    // Get user from database
    const userResult = await getUserByEmail(db, TEST_USER_EMAIL)
    console.log("User query result:", JSON.stringify(userResult))

    if (!userResult || userResult.length === 0) {
      throw new Error(
        `User ${TEST_USER_EMAIL} not found in database. Please ensure this user exists or set TEST_USER_EMAIL environment variable to a valid user email.`,
      )
    }

    const user = userResult[0]
    console.log(
      `Found user: ${user.email} with role: ${user.role} in workspace: ${user.workspaceExternalId}`,
    )

    // Generate tokens using the same logic as the server
    const accessToken = await generateTokens(
      user.email,
      user.role,
      user.workspaceExternalId,
    )
    const refreshToken = await generateTokens(
      user.email,
      user.role,
      user.workspaceExternalId,
      true,
    )

    // Format cookies the same way the server does
    const accessTokenCookie = `${AccessTokenCookieName}=${accessToken}`
    const refreshTokenCookie = `${RefreshTokenCookieName}=${refreshToken}`

    // Combine cookies for the script to use
    const scriptCookies = `${accessTokenCookie}; ${refreshTokenCookie}`
    console.log("Successfully generated authentication tokens.")
    return scriptCookies
  } catch (error) {
    console.error("Error generating authentication tokens:", error)
    throw error
  }
}

/**
 * Read cookies from environment variable TEST_API_COOKIES
 */
function getCookiesFromEnv(): string | null {
  const cookies = process.env.TEST_API_COOKIES
  return cookies && cookies.trim() !== "" ? cookies : null
}

/**
 * Update the TEST_API_COOKIES environment variable in the .env file
 */
function updateCookiesInEnv(newCookies: string) {
  try {
    const envPath = join(process.cwd(), ".env")
    let envContent = readFileSync(envPath, "utf8")

    // Replace the TEST_API_COOKIES line
    const cookieRegex = /^TEST_API_COOKIES\s*=.*$/m
    if (cookieRegex.test(envContent)) {
      envContent = envContent.replace(
        cookieRegex,
        `TEST_API_COOKIES = "${newCookies}"`,
      )
    } else {
      // If not found, append it
      envContent += `\nTEST_API_COOKIES = "${newCookies}"`
    }

    writeFileSync(envPath, envContent, "utf8")
    console.log("Successfully updated TEST_API_COOKIES in .env file")

    // Update the current process environment as well
    process.env.TEST_API_COOKIES = newCookies
  } catch (error) {
    console.error("Error updating .env file:", error)
    throw error
  }
}

/**
 * Parse agentic mode responses that contain JAF (Juspay Agentic Framework) events
 * JAF events have specific structure for final outputs in run_end and final_output events
 */
function parseAgenticResponse(text: string): string {
  try {
    // Extract answer between synthesize_final_answer and synthesis_completed
    // Find the LAST occurrence of "Composing your answer" + "synthesize_final_answer"
    let lastJsonStart = -1
    let searchPos = 0
    while (true) {
      const composingIdx = text.indexOf(
        '"displayText":"Composing your answer."',
        searchPos,
      )
      if (composingIdx === -1) break

      // Check if this composing event has synthesize_final_answer
      const contextEnd = Math.min(composingIdx + 500, text.length)
      const context = text.substring(composingIdx, contextEnd)
      if (context.includes('"toolName":"synthesize_final_answer"')) {
        // Find the START of this JSON object (the opening brace before composingIdx)
        let jsonStart = composingIdx
        while (jsonStart > 0 && text[jsonStart] !== "{") {
          jsonStart--
        }
        lastJsonStart = jsonStart
      }
      searchPos = composingIdx + 1
    }

    if (lastJsonStart !== -1) {
      // Find the end of this JSON object
      let braceCount = 0
      let jsonEnd = -1
      for (let i = lastJsonStart; i < text.length; i++) {
        if (text[i] === "{") braceCount++
        if (text[i] === "}") {
          braceCount--
          if (braceCount === 0) {
            jsonEnd = i + 1
            break
          }
        }
      }

      if (jsonEnd !== -1) {
        // Include the synthesize_final_answer JSON block + the actual answer text
        const synthesizeJson = text.substring(lastJsonStart, jsonEnd)
        let answerText = text.substring(jsonEnd)

        // Find synthesis_completed event
        const synthCompleteIdx = answerText.indexOf(
          '{"type":"synthesis_completed"',
        )
        if (synthCompleteIdx !== -1) {
          answerText = answerText.substring(0, synthCompleteIdx)
        }

        // Remove citation metadata JSON blocks but keep the synthesize JSON
        answerText = answerText.replace(
          /\{[^{}]*"contextChunks"[^{}]*"citationMap"[^{}]*\}/gs,
          " ",
        )

        // Clean up whitespace
        answerText = answerText.replace(/\s+/g, " ").trim()

        // Combine: synthesize JSON + answer text
        const fullAnswer = synthesizeJson + answerText

        if (fullAnswer.length > 50) {
          return cleanUpAnswer(fullAnswer)
        }
      }
    }

    // Fallback: parse JSON objects
    const jsonObjects = []
    let braceCount = 0
    let currentJson = ""

    for (let i = 0; i < text.length; i++) {
      const char = text[i]

      if (char === "{") {
        if (braceCount === 0) {
          currentJson = ""
        }
        braceCount++
      }

      currentJson += char

      if (char === "}") {
        braceCount--
        if (braceCount === 0) {
          try {
            const parsed = JSON.parse(currentJson)
            jsonObjects.push(parsed)
          } catch (e) {
            // Skip invalid JSON
          }
          currentJson = ""
        }
      }
    }

    console.log(`Found ${jsonObjects.length} JSON objects in agentic response`)

    // PRIORITY 1b: Also check for tool_call_end with synthesize_final_answer
    for (let i = 0; i < jsonObjects.length; i++) {
      const obj = jsonObjects[i]
      if (
        obj.type === "tool_call_end" &&
        obj.data?.tool_name === "synthesize_final_answer" &&
        obj.data?.final_output
      ) {
        console.log(
          "Found synthesize_final_answer tool_call_end with final_output",
        )
        return cleanUpAnswer(obj.data.final_output)
      }
    }

    // PRIORITY 2: Look for JAF "final_output" events
    for (const obj of jsonObjects) {
      if (
        obj.type === "final_output" &&
        obj.data?.output &&
        typeof obj.data.output === "string"
      ) {
        console.log("Found JAF final_output event with data.output")
        return cleanUpAnswer(obj.data.output)
      }
    }

    // PRIORITY 3: Look for JAF "run_end" events with completed status and output
    for (const obj of jsonObjects) {
      if (
        obj.type === "run_end" &&
        obj.data?.outcome?.status === "completed" &&
        obj.data?.outcome?.output
      ) {
        console.log(
          "Found JAF run_end event with completed status and outcome.output",
        )
        return cleanUpAnswer(obj.data.outcome.output)
      }
    }

    // PRIORITY 4: Look for any JAF "run_end" events with output
    for (const obj of jsonObjects) {
      if (obj.type === "run_end" && obj.data?.outcome?.output) {
        console.log("Found JAF run_end event with outcome.output")
        return cleanUpAnswer(obj.data.outcome.output)
      }
    }

    // PRIORITY 5: Look for assistant_message events without tool_calls
    for (const obj of jsonObjects) {
      if (
        obj.type === "assistant_message" &&
        obj.data?.message?.content &&
        typeof obj.data.message.content === "string" &&
        !obj.data.message.tool_calls
      ) {
        console.log("Found JAF assistant_message event with final content")
        return cleanUpAnswer(obj.data.message.content)
      }
    }

    // PRIORITY 6: Accumulate all assistant_message content
    let accumulatedAnswer = ""
    for (const obj of jsonObjects) {
      if (
        obj.type === "assistant_message" &&
        obj.data?.message?.content &&
        typeof obj.data.message.content === "string" &&
        !obj.data.message.tool_calls
      ) {
        accumulatedAnswer += obj.data.message.content
      }
    }

    if (accumulatedAnswer.trim()) {
      console.log("Found accumulated assistant_message content")
      return cleanUpAnswer(accumulatedAnswer)
    }

    console.log("No meaningful content found in JAF events")
    return cleanUpAnswer(text)
  } catch (error) {
    console.warn("Error parsing agentic JAF response:", error)
    return cleanUpAnswer(text)
  }
}

/**
 * Clean up the answer by removing citations, metadata, and extra formatting
 */
function cleanUpAnswer(answer: string): string {
  if (!answer || typeof answer !== "string") {
    return ""
  }

  let cleaned = answer

  // Remove citation metadata objects like {"contextChunks":[...],"citationMap":{...}}
  // But preserve any text that comes after it
  cleaned = cleaned.replace(
    /^\s*\{"contextChunks":\[.*?\],"citationMap":\{.*?\}\}\s*/gs,
    "",
  )

  // Remove citations like [1], [2], [1,2], etc.
  cleaned = cleaned.replace(/\[\d+(?:,\s*\d+)*\]/g, "")

  // Remove multiple consecutive spaces and normalize whitespace
  cleaned = cleaned.replace(/\s+/g, " ")

  // Remove leading/trailing whitespace
  cleaned = cleaned.trim()

  // Remove any remaining JSON artifacts
  cleaned = cleaned.replace(/^["']|["']$/g, "")

  // Remove escape characters
  cleaned = cleaned
    .replace(/\\n/g, "\n")
    .replace(/\\r/g, "\r")
    .replace(/\\"/g, '"')

  return cleaned
}

/**
 * Test API with given cookies (with retry logic and auto-refresh on 401)
 * Includes timeout to prevent hanging on SSE streams
 */
async function testAPI(
  query: string,
  cookies: string,
  questionId: string | number,
  maxRetries: number = 3,
): Promise<{ answer: string | null; success: boolean; cookies: string }> {
  const apiPort = process.env.API_PORT || "3000"
  const agenticUrl =
    `http://localhost:${apiPort}/api/v1/message/create?` +
    `message=${encodeURIComponent(query)}&` +
    `selectedModelConfig=${encodeURIComponent(
      JSON.stringify({
        model: process.env.TEST_MODEL || "private-large",
        reasoning: true,
        websearch: false,
        deepResearch: false,
      }),
    )}&` +
    `agentic=true`

  console.log(
    `\n🚀 Processing Question ID ${questionId}: "${query.substring(0, 100)}${
      query.length > 100 ? "..." : ""
    }"`,
  )
  console.log(`📍 API URL: ${agenticUrl}`)
  console.log("---")

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      if (attempt > 1) {
        console.log(
          `🔄 Retry attempt ${attempt}/${maxRetries} for question ${questionId}...`,
        )
        // Wait before retry (exponential backoff: 2s, 4s, 8s)
        await new Promise((resolve) =>
          setTimeout(resolve, Math.pow(2, attempt) * 1000),
        )
      }

      // Create AbortController for timeout
      const controller = new AbortController()
      const timeoutMs = 120000 // 2 minute timeout for the entire request
      const timeoutId = setTimeout(() => {
        console.log(`⏰ Request timeout after ${timeoutMs}ms, aborting...`)
        controller.abort()
      }, timeoutMs)

      const response = await fetch(agenticUrl, {
        method: "GET",
        headers: {
          Cookie: cookies,
          Accept: "text/event-stream",
          "User-Agent": "XyneAPITester/1.0",
        },
        signal: controller.signal,
      })

      console.log(`📊 API Response Status: ${response.status}`)

      // Clear the timeout since we got a response
      clearTimeout(timeoutId)

      if (!response.ok) {
        console.log(`❌ API request failed with status: ${response.status}`)

        // Handle 401 Unauthorized - regenerate cookies and retry
        if (response.status === 401 && attempt < maxRetries) {
          console.log(
            `🔐 Token expired! Regenerating authentication cookies...`,
          )
          try {
            const newCookies = await generateAuthenticationCookies()
            updateCookiesInEnv(newCookies)
            cookies = getCookiesFromEnv() || newCookies
            console.log(`✅ Cookies regenerated, retrying question...`)
            continue
          } catch (authError) {
            console.error(`❌ Failed to regenerate cookies:`, authError)
            return { answer: null, success: false, cookies }
          }
        }

        // For 5xx errors, retry; for other 4xx errors, don't retry
        if (response.status >= 500 && attempt < maxRetries) {
          console.log(`⏳ Server error, will retry...`)
          continue
        }
        return { answer: null, success: false, cookies }
      }

      // Process the streaming response with a read timeout
      const reader = response.body?.getReader()
      const decoder = new TextDecoder()
      let rawResult = ""
      let lastChunkTime = Date.now()
      const chunkTimeoutMs = 30000 // 30 seconds without new data = timeout

      if (reader) {
        while (true) {
          // Check for chunk timeout
          if (Date.now() - lastChunkTime > chunkTimeoutMs) {
            console.log(
              `⏰ No data received for ${chunkTimeoutMs}ms, breaking stream...`,
            )
            reader.cancel()
            break
          }

          const { done, value } = await reader.read()
          if (done) break

          lastChunkTime = Date.now() // Reset timeout on new data

          const chunk = decoder.decode(value)
          const lines = chunk.split("\n")

          for (const line of lines) {
            if (
              line.startsWith("data: ") &&
              !line.includes("chatId") &&
              !line.includes("messageId") &&
              line.slice(6).trim() !== "[DONE]"
            ) {
              const data = line.slice(6)
              if (data.trim()) {
                rawResult += data
              }
            }
          }
        }
      }

      console.log(
        `📝 API response completed, length: ${rawResult.length} chars`,
      )

      // Parse the agentic response to extract the answer
      const parsedAnswer = parseAgenticResponse(rawResult)
      console.log(`✅ Parsed answer length: ${parsedAnswer.length} chars`)

      return { answer: parsedAnswer, success: true, cookies }
    } catch (error) {
      const errorCode = (error as any).code || "UNKNOWN"
      console.error(
        `❌ Error during API test for question ${questionId} (attempt ${attempt}/${maxRetries}):`,
        errorCode,
      )

      // Connection refused or network errors - retry
      const isRetryable = [
        "ECONNRESET",
        "ConnectionRefused",
        "ETIMEDOUT",
        "ECONNREFUSED",
      ].includes(errorCode)

      if (isRetryable && attempt < maxRetries) {
        console.log(`⏳ Connection issue, waiting before retry...`)
        // Wait longer for connection issues (5s, 10s, 15s)
        await new Promise((resolve) => setTimeout(resolve, attempt * 5000))
        continue
      }

      // Non-retryable error or last attempt
      if (!isRetryable || attempt === maxRetries) {
        return { answer: null, success: false, cookies }
      }
    }
  }

  return { answer: null, success: false, cookies }
}

/**
 * Validate authentication by testing with a simple query
 */
async function validateAuthentication(cookies: string): Promise<boolean> {
  const testQuery = "Hello, this is a test query for authentication validation."
  const apiPort = process.env.API_PORT || "3000"
  const testModel = process.env.TEST_MODEL || "private-large"

  console.log("🔐 Validating authentication with test query...")

  try {
    const url = `http://localhost:${apiPort}/api/v1/message/create?selectedModelConfig=${encodeURIComponent(
      JSON.stringify({
        model: testModel,
        reasoning: false,
        websearch: false,
        deepResearch: false,
      }),
    )}&message=${encodeURIComponent(testQuery)}`

    const response = await fetch(url, {
      method: "GET",
      headers: {
        Cookie: cookies,
        Accept: "text/event-stream",
        "User-Agent": "XyneAPITester/1.0",
      },
    })

    const isValid = response.ok
    console.log(
      `🔐 Authentication validation: ${
        isValid ? "✅ Valid" : "❌ Invalid"
      } (Status: ${response.status})`,
    )
    return isValid
  } catch (error) {
    console.error("🔐 Authentication validation error:", error)
    return false
  }
}

/**
 * Main function that processes QA data
 */
async function main() {
  console.log("🎯 Starting API test with QA data...\n")

  try {
    // --- File paths ---
    const qaInputPath = join(
      process.cwd(),
      "xyne-evals",
      "qa_pipelines",
      "generation_through_vespa",
      "output",
      "qa_output_hard.json",
    )
    const testModel = process.env.TEST_MODEL || "private-large"
    const resultsDir = process.env.RESULTS_DIR || join(process.cwd(), "results")
    const timestamp = new Date()
      .toISOString()
      .replace(/[:.]/g, "-")
      .slice(0, 19)
    const outputPath = join(
      resultsDir,
      `test_api_v6_results_${testModel}_${timestamp}.json`,
    )

    console.log(`📂 Reading QA data from: ${qaInputPath}`)

    if (!existsSync(qaInputPath)) {
      throw new Error(`Input file not found: ${qaInputPath}`)
    }

    const qaData = JSON.parse(readFileSync(qaInputPath, "utf-8"))
    console.log(`Found ${qaData.length} questions in the input file.`)

    // --- Slice Configuration ---
    // Get slice parameters from command line arguments or use defaults
    const startIndex = parseInt(process.argv[2]) || 0
    const count = parseInt(process.argv[3]) || 3 // Process 3 questions by default
    const batchSize = parseInt(process.argv[4]) || 10 // Process in batches of 10 by default
    const endIndex = Math.min(startIndex + count, qaData.length)
    const questionsToProcess = qaData.slice(startIndex, endIndex)

    console.log(`🔪 Slice Configuration:`)
    console.log(`   Start Index: ${startIndex}`)
    console.log(`   Count: ${count}`)
    console.log(`   Batch Size: ${batchSize}`)
    console.log(`   End Index: ${endIndex}`)
    console.log(
      `   Processing ${
        questionsToProcess.length
      } questions (from index ${startIndex} to ${endIndex - 1})`,
    )
    console.log(
      `   Usage: bun run test_api_v6.ts <startIndex> <count> <batchSize>`,
    )
    console.log(
      `   Example: bun run test_api_v6.ts 0 100 10 (process 100 questions in batches of 10)`,
    )
    console.log("")

    // --- Cookie Management ---
    console.log("🔍 Step 1: Getting cookies from environment variable...")
    let cookies = getCookiesFromEnv()

    if (cookies) {
      console.log("✅ Found existing cookies. Testing their validity...")
      const isValid = await validateAuthentication(cookies)

      if (!isValid) {
        console.log("⚠️ Existing cookies are invalid. Regenerating...")
        cookies = null
      } else {
        console.log("✅ Existing cookies are valid.")
      }
    }

    if (!cookies) {
      console.log("\n🔐 Generating new authentication cookies...")
      const newCookies = await generateAuthenticationCookies()
      updateCookiesInEnv(newCookies)
      cookies = getCookiesFromEnv()
      if (!cookies) {
        throw new Error(
          "Failed to obtain valid cookies even after regeneration.",
        )
      }
      console.log("✅ Successfully generated and stored new cookies.")
    }

    console.log("🍪 Using cookies:", cookies.substring(0, 50) + "...")

    // --- Initialize output ---
    // Load existing results if the file exists, otherwise start with empty array
    let existingResults: any[] = []
    if (existsSync(outputPath)) {
      try {
        const existingContent = readFileSync(outputPath, "utf-8")
        existingResults = JSON.parse(existingContent)
        console.log(
          `📚 Found existing results file with ${existingResults.length} entries`,
        )
      } catch (error) {
        console.warn(`⚠️  Could not read existing results file: ${error}`)
        existingResults = []
      }
    } else {
      console.log(`📄 No existing results file found, starting fresh`)
    }

    let allNewResults: any[] = []

    // --- Filter out already processed questions ---
    const doneQuestionIds = new Set(
      existingResults.map((r) => r.question_id || r.Question?.substring(0, 50)),
    )
    const questionsToActuallyProcess = questionsToProcess.filter((q) => {
      const qId = q.question_id || q.Question?.substring(0, 50)
      if (doneQuestionIds.has(qId)) {
        console.log(`⏭️  Skipping already processed question: ${qId}`)
        return false
      }
      return true
    })

    console.log(`📊 Questions already done: ${doneQuestionIds.size}`)
    console.log(
      `📊 Questions to process now: ${questionsToActuallyProcess.length}`,
    )

    if (questionsToActuallyProcess.length === 0) {
      console.log("✅ All questions already processed. Nothing to do.")
      return
    }

    // --- Batch Processing Loop (Sequential with delays) ---
    for (let i = 0; i < questionsToActuallyProcess.length; i += batchSize) {
      const batch = questionsToActuallyProcess.slice(i, i + batchSize)
      console.log(
        `\n✨ Processing batch ${i / batchSize + 1} (questions ${i + 1} to ${
          i + batch.length
        })`,
      )

      // Process sequentially instead of concurrently to avoid overwhelming the server
      const batchResults: any[] = []
      for (let j = 0; j < batch.length; j++) {
        const item = batch[j]
        const questionIndex = startIndex + i + j
        const query = item.Question
        const questionId = item.question_id || `q_${questionIndex + 1}`

        console.log("-".repeat(50))
        console.log(
          `  🚀 Starting Question ${i + j + 1}/${
            questionsToActuallyProcess.length
          } (ID: ${questionId})`,
        )

        const result = await testAPI(query, cookies, questionId)

        // Update cookies if they were refreshed during the call
        if (result.cookies !== cookies) {
          cookies = result.cookies
          console.log(`🍪 Updated cookies after API call`)
        }

        batchResults.push({
          ...item,
          Agentic_answer: result.answer || "",
          Tool_results: [],
        })

        // Add delay between questions (except for the last one in batch)
        if (j < batch.length - 1) {
          const delayMs = 2000 // 2 seconds between questions
          console.log(`⏳ Waiting ${delayMs}ms before next question...`)
          await new Promise((resolve) => setTimeout(resolve, delayMs))
        }
      }

      allNewResults.push(...batchResults)

      // Save intermediate results after each batch
      // Use initial existingResults + allNewResults to avoid duplicates
      const combinedIntermediate = [...existingResults, ...allNewResults]
      writeFileSync(
        outputPath,
        JSON.stringify(combinedIntermediate, null, 2),
        "utf-8",
      )
      console.log(
        `\n💾 Saved intermediate results for batch ${
          i / batchSize + 1
        }. Total entries: ${combinedIntermediate.length}`,
      )
    }

    // --- Final Save ---
    const finalResults = [...existingResults, ...allNewResults]
    writeFileSync(outputPath, JSON.stringify(finalResults, null, 2), "utf-8")

    // --- Final Summary ---
    const successCount = allNewResults.filter(
      (r) => r.Agentic_answer && r.Agentic_answer.length > 0,
    ).length

    console.log("\n" + "=".repeat(100))
    console.log("🎉 PROCESSING COMPLETE")
    console.log("=".repeat(100))
    console.log(
      `📊 Total questions processed this run: ${allNewResults.length}`,
    )
    console.log(
      `✅ Successful answers extracted: ${successCount}/${allNewResults.length}`,
    )
    console.log(`📁 Total entries in final file: ${finalResults.length}`)
    console.log(`💾 Final results saved to: ${outputPath}`)
    console.log("=".repeat(100))
  } catch (error) {
    console.error("💥 Error in main function:", error)
    process.exit(1)
  }
}

// Run the script
main()
  .then(() => {
    console.log("✅ Script completed successfully")
    process.exit(0)
  })
  .catch((error) => {
    console.error("💥 Script failed:", error)
    process.exit(1)
  })
