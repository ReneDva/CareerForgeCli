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

type LockedLink = {
    label: string;
    url: string;
};

function extractLockedLinksFromMarkdown(markdown: string): LockedLink[] {
    if (!markdown || !markdown.trim()) {
        return [];
    }

    const links: LockedLink[] = [];
    const seen = new Set<string>();
    const markdownLinkRegex = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/gi;

    let match: RegExpExecArray | null;
    while ((match = markdownLinkRegex.exec(markdown)) !== null) {
        const label = (match[1] || 'Link').trim();
        const url = (match[2] || '').trim();
        if (!url) continue;

        const dedupeKey = `${label.toLowerCase()}|${url.toLowerCase()}`;
        if (!seen.has(dedupeKey)) {
            seen.add(dedupeKey);
            links.push({ label, url });
        }
    }

    return links;
}

function buildLockedLinksInstruction(lockedLinks: LockedLink[]): string {
    if (lockedLinks.length === 0) {
        return `- No source links were provided in the base markdown profile.`;
    }

    const lines = lockedLinks.map((item, index) => `${index + 1}. [${item.label}](${item.url})`);
    return [
        `LOCKED SOURCE LINKS (copy exactly, character-for-character):`,
        ...lines,
        `Rules:`,
        `- Do NOT change protocol/domain/path/query/fragment in any listed URL.`,
        `- Do NOT replace with generic homepage links.`,
        `- Do NOT invent, normalize, shorten, or "fix" URLs.`,
        `- If the resume includes these links, they must be exactly identical to source markdown.`
    ].join("\n");
}

function validateLockedLinksInHtmlOrThrow(html: string, lockedLinks: LockedLink[]): void {
    if (!lockedLinks.length) {
        return;
    }

    const missing = lockedLinks.filter((item) => !html.includes(item.url));
    if (missing.length > 0) {
        const missingSummary = missing.map((item) => `${item.label}: ${item.url}`).join(', ');
        throw new Error(`Generated HTML is missing locked profile links: ${missingSummary}`);
    }
}

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
    const lockedLinks = extractLockedLinksFromMarkdown(profile.content);
    const lockedLinksInstruction = buildLockedLinksInstruction(lockedLinks);

    const prompt = `
    TASK: Generate a high-impact, 1-page HTML resume using Gemini 2.5 Pro capabilities.
    USER_PROFILE: ${profile.content}
    TARGET_JOB: ${job.title} - ${job.description}

    CONSTRAINTS for Automation:
    - Use inline CSS for layout stability.
    - Ensure a professional, modern look.
    - Output MUST be valid HTML5.
    - Avoid external JS; minimize external web fonts to ensure fast PDF rendering.

    LINK INTEGRITY CONSTRAINTS:
    ${lockedLinksInstruction}

    TRUTHFULNESS CONSTRAINTS:
    - Do NOT invent achievements, employers, dates, titles, links, repositories, education, or certifications.
    - Do NOT exaggerate measurable impact; only use facts explicitly present in USER_PROFILE.
    - If information is missing, omit it instead of guessing.
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
        const parsed = JSON.parse(text) as GeneratedAssets;
        validateLockedLinksInHtmlOrThrow(parsed.resumeHtml, lockedLinks);
        return parsed;
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
    const lockedLinks = extractLockedLinksFromMarkdown(profile.content);
    const lockedLinksInstruction = buildLockedLinksInstruction(lockedLinks);
    const prompt = `Surgically refine this Resume HTML to perfectly match the JD keywords: ${job.description}.

Current HTML: ${currentHtml}

SOURCE PROFILE: ${profile.content}

CRITICAL CONSTRAINTS:
${lockedLinksInstruction}
- Keep the existing structure and formatting style unless a change is required for factual correctness or ATS relevance.
- Preserve existing links exactly when present and never replace a user-specific link with a generic home page.
- Never add fabricated or exaggerated claims.`;

    return await withRetry(async () => {
        const response = await ai.models.generateContent({
            model: judgeModel,
            contents: prompt,
            config: {
                responseMimeType: "text/plain",
                thinkingConfig: { thinkingBudget: 4096 },
                systemInstruction: "Refine the HTML content for maximum ATS compatibility. Preserve locked links exactly and do not invent facts. Output ONLY the raw HTML code.",
            }
        });

        const cleanedHtml = response.text || "";
        // Extract HTML block using regex to avoid potential markdown wrap in response
        const htmlMatch = cleanedHtml.match(/(?:<!DOCTYPE html>|<html)[\s\S]*<\/html>/i);
        const resultHtml = htmlMatch ? htmlMatch[0] : cleanedHtml.replace(/^\s*```html/, '').replace(/\s*```$/, '').trim();
        validateLockedLinksInHtmlOrThrow(resultHtml, lockedLinks);
        return resultHtml;
    });
};