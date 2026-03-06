import { GoogleGenAI, Type, type Schema } from "@google/genai";
import { UserProfile, JobDetails, GeneratedAssets } from "./types";

/**
 * gemini.ts
 * MODEL CONFIGURATION UPDATE (2026-03-05)
 * 1. Upgraded to Gemini 2.5 Pro for enhanced tailoring accuracy.
 * 2. Implemented pre-emptive throttling and aggressive backoff to handle rate limits.
 */
const GENERATOR_MODEL = 'gemini-2.5-pro';
const JUDGE_MODEL = 'gemini-2.5-pro';

const ALLOWED_MODEL_ALIASES: Record<string, string> = {
    'google/gemini-3-pro-preview': 'gemini-3-pro-preview',
    'google/gemini-2.5-pro': 'gemini-2.5-pro',
    'google/gemini-2.0-flash': 'gemini-2.0-flash',
    'gemini-3-pro-preview': 'gemini-3-pro-preview',
    'gemini-2.5-pro': 'gemini-2.5-pro',
    'gemini-2.0-flash': 'gemini-2.0-flash'
};

function resolveAllowedModelOrThrow(rawModel?: string): string {
    if (!rawModel || !rawModel.trim()) {
        return GENERATOR_MODEL;
    }

    const key = rawModel.trim().toLowerCase();
    const resolved = ALLOWED_MODEL_ALIASES[key];
    if (!resolved) {
        throw new Error(
            `Model '${rawModel}' is not in allowlist. Allowed: ${Object.keys(ALLOWED_MODEL_ALIASES)
                .filter((k) => k.startsWith('google/'))
                .join(', ')}`
        );
    }

    return resolved;
}

/**
 * 2026 INTERNAL DOCUMENTATION:
 * 1. Pacing Logic: Mandatory 5s base delay on retries to avoid 429/503 spikes.
 * 2. Automation-Friendly HTML: Strict inline CSS constraints for Puppeteer stability.
 */

export async function checkModelHealth(context: any) {
    if (context.model?.id === 'google/gemini-2.5-pro') {
        process.stderr.write("[INFO] Running on Gemini 2.5 Pro architecture.\n");
    }
}

/**
 * Handles API calls with exponential backoff.
 * Increased initial delay to 5000ms for Gemini 2.5 stability.
 */
async function withRetry<T>(fn: () => Promise<T>, retries = 5, delay = 5000): Promise<T> {
    try {
        return await fn();
    } catch (error: any) {
        const errorMessage = error.message?.toLowerCase() || "";
        const isOverloaded = errorMessage.includes("overloaded") ||
                           errorMessage.includes("503") ||
                           errorMessage.includes("429");

        if (isOverloaded && retries > 0) {
            const statusMsg = `[SYSTEM-NOTICE] Gemini 2.5 Pro API busy. Retrying in ${delay / 1000}s... (${retries} attempts left)`;
            process.stderr.write(`${statusMsg}\n`);
            await new Promise(res => setTimeout(res, delay));
            // Exponentially increase delay for the next attempt
            return withRetry(fn, retries - 1, delay * 2);
        }
        process.stderr.write(`[CRITICAL-ERROR] Gemini 2.5 failed: ${error.message}\n`);
        throw error;
    }
}

export const generateApplicationAssets = async (
    profile: UserProfile,
    job: JobDetails,
    apiKey: string,
    modelOverride?: string
): Promise<GeneratedAssets> => {
    if (!apiKey) throw new Error("API Key missing.");

    const ai = new GoogleGenAI({ apiKey });

    // Define JSON schema for structured output
    const dynamicSchema: Schema = {
        type: Type.OBJECT,
        properties: {
            resumeHtml: {
                type: Type.STRING,
                description: "Complete stand-alone HTML document."
            }
        },
        required: ["resumeHtml"]
    };

    const generatorModel = resolveAllowedModelOrThrow(modelOverride);

    const prompt = `
    TASK: Generate a high-impact, 1-page HTML resume using Gemini 2.5 Pro capabilities.
    USER_PROFILE: ${profile.content}
    TARGET_JOB: ${job.title} - ${job.description}

    CONSTRAINTS for Automation:
    - Use inline CSS for layout stability.
    - Ensure a professional, modern look.
    - Output MUST be valid HTML5.
    - Avoid external JS; minimize external web fonts to ensure fast PDF rendering.
    `;

    return await withRetry(async () => {
        const response = await ai.models.generateContent({
            model: generatorModel,
            contents: prompt,
            config: {
                responseMimeType: "application/json",
                responseSchema: dynamicSchema,
                // Thinking budget utilized for complex cross-referencing between profile and JD
                thinkingConfig: { thinkingBudget: 4096 },
                systemInstruction: "You are an executive career strategist. Create HTML that is clean, professional, and optimized for PDF conversion. Ensure all content fits on one A4 page.",
            },
        });

        const text = response.text;
        if (!text) throw new Error("Empty response from Gemini.");
        return JSON.parse(text) as GeneratedAssets;
    });
};

export const refineResume = async (
    currentHtml: string,
    job: JobDetails,
    profile: UserProfile,
    apiKey: string,
    modelOverride?: string
): Promise<string> => {
    if (!apiKey) throw new Error("API Key missing.");

    const ai = new GoogleGenAI({ apiKey });
    const judgeModel = resolveAllowedModelOrThrow(modelOverride);
    const prompt = `Surgically refine this Resume HTML to perfectly match the JD keywords: ${job.description}. Current HTML: ${currentHtml}`;

    return await withRetry(async () => {
        const response = await ai.models.generateContent({
            model: judgeModel,
            contents: prompt,
            config: {
                responseMimeType: "text/plain",
                thinkingConfig: { thinkingBudget: 4096 },
                systemInstruction: "Refine the HTML content for maximum ATS compatibility. Output ONLY the raw HTML code.",
            }
        });

        const cleanedHtml = response.text || "";
        // Extract HTML block using regex to avoid potential markdown wrap in response
        const htmlMatch = cleanedHtml.match(/(?:<!DOCTYPE html>|<html)[\s\S]*<\/html>/i);
        return htmlMatch ? htmlMatch[0] : cleanedHtml.replace(/^\s*```html/, '').replace(/\s*```$/, '').trim();
    });
};