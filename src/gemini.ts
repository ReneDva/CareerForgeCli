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
    placeholder: string;
};

type PersonalGuardrails = {
    requiredTokens: string[];
    sourceHasAddressTerms: boolean;
    sourceHasResidenceTerms: boolean;
    educationCoreFacts: string[];
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
            links.push({
                label,
                url,
                placeholder: `__LOCKED_LINK_${links.length + 1}__`
            });
        }
    }

    return links;
}

function applyLinkPlaceholdersToText(text: string, lockedLinks: LockedLink[]): string {
    let output = text;
    for (const link of lockedLinks) {
        output = output.split(link.url).join(link.placeholder);
    }
    return output;
}

function restoreLinkPlaceholdersInText(text: string, lockedLinks: LockedLink[]): string {
    let output = text;
    for (const link of lockedLinks) {
        output = output.split(link.placeholder).join(link.url);
    }
    return output;
}

function extractImmutablePersonalBlock(markdown: string): string {
    if (!markdown || !markdown.trim()) {
        return '';
    }

    const firstSeparator = markdown.indexOf('\n---');
    if (firstSeparator <= 0) {
        return markdown.trim();
    }
    return markdown.slice(0, firstSeparator).trim();
}

function extractSection(markdown: string, sectionTitle: string): string {
    if (!markdown || !markdown.trim()) {
        return '';
    }

    const escaped = sectionTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const regex = new RegExp(`(^|\\n)##\\s+${escaped}\\s*\\n([\\s\\S]*?)(?=\\n##\\s+|$)`, 'i');
    const match = markdown.match(regex);
    return match && match[2] ? match[2].trim() : '';
}

function normalizeToken(s: string): string {
    return s.replace(/\s+/g, ' ').trim();
}

function canonicalizeFactText(s: string): string {
    return s
        .replace(/<[^>]*>/g, ' ')
        .replace(/[\u2012\u2013\u2014\u2015]/g, '-')
        .replace(/\s*\|\s*/g, ' | ')
        .replace(/\s+/g, ' ')
        .trim()
        .toLowerCase();
}

function tokenizeWords(s: string): string[] {
    return canonicalizeFactText(s)
    .split(/[^\p{L}\p{N}]+/u)
        .map((t) => t.trim())
        .filter((t) => t.length >= 3);
}

function hasEducationFactMatch(canonicalHtml: string, fact: string): boolean {
    const canonicalFact = canonicalizeFactText(fact);
    if (!canonicalFact) {
        return true;
    }

    // Fast path: exact normalized substring
    if (canonicalHtml.includes(canonicalFact)) {
        return true;
    }

    // Loose path: years + significant tokens coverage
    const htmlWordSet = new Set(tokenizeWords(canonicalHtml));
    const factWords = tokenizeWords(canonicalFact);
    const yearMatches = canonicalFact.match(/\b(19|20)\d{2}\b/g) || [];

    const missingYear = yearMatches.some((year) => !canonicalHtml.includes(year));
    if (yearMatches.length > 0 && missingYear) {
        return false;
    }

    if (factWords.length === 0) {
        return yearMatches.length === 0 || !missingYear;
    }

    const stopWords = new Set(['the', 'and', 'for', 'with', 'from', 'that', 'this', 'of', 'in']);
    const meaningful = factWords.filter((w) => !stopWords.has(w));
    const sourceWords = meaningful.length > 0 ? meaningful : factWords;

    let hit = 0;
    for (const w of sourceWords) {
        if (htmlWordSet.has(w)) {
            hit++;
        }
    }

    const requiredHits = Math.max(2, Math.ceil(sourceWords.length * 0.6));
    return hit >= requiredHits;
}

function extractImmutableEducationCoreFacts(markdown: string): string[] {
    const educationSection = extractSection(markdown, 'Education');
    if (!educationSection) {
        return [];
    }

    const tokens = new Set<string>();
    const lines = educationSection.split(/\r?\n/).map((l) => l.trim()).filter((l) => !!l);

    for (const line of lines) {
        const isLikelyHeading = /^#{2,6}\s+/.test(line) || /^\*\*[^*]+\*\*$/.test(line);
        if (!isLikelyHeading) continue;

        const cleaned = normalizeToken(
            line
                .replace(/^[\s#*\-]+/, '')
                .replace(/^#{1,6}\s*/, '')
                .replace(/\*\*/g, '')
                .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
        );

        if (!cleaned) continue;
        if (/selected\s+academic\s*&\s*personal\s+projects?/i.test(cleaned)) continue;
        if (/^\d{4}\s*[\-–]\s*\d{4}\s*$/i.test(cleaned)) continue;

        const isSecondaryEducation = /\b(high school|secondary school|bagrut|matriculation)\b/i.test(cleaned);
        const hasStudyKeywords = /\b(b\.?sc\.?|msc|phd|track|program|college|university|academic|computer science|engineering|seminary)\b/i.test(cleaned);
        const hasYearPattern = /\b(19|20)\d{2}\b/.test(cleaned);
        const hasInstitutionDelimiter = /\|/.test(cleaned);

        if (isSecondaryEducation) {
            // Keep core immutable validation focused on higher-education facts only.
            // Secondary-school lines are allowed to be compacted/omitted for one-page output.
            continue;
        }

        if (hasStudyKeywords || (hasYearPattern && hasInstitutionDelimiter)) {
            if (cleaned.length >= 4) {
                tokens.add(cleaned);
            }
        }
    }

    return Array.from(tokens).slice(0, 12);
}

function buildPersonalGuardrails(markdown: string): PersonalGuardrails {
    const immutableBlock = extractImmutablePersonalBlock(markdown);
    const tokens = new Set<string>();

    const emailMatches = immutableBlock.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) || [];
    for (const m of emailMatches) {
        tokens.add(m.trim());
    }

    const phoneMatches = immutableBlock.match(/\+?\d[\d\s\-()]{6,}\d/g) || [];
    for (const m of phoneMatches) {
        tokens.add(m.trim());
    }

    const nameLine = immutableBlock
        .split(/\r?\n/)
        .map((line) => line.replace(/^#+\s*/, '').trim())
        .find((line) => !!line);
    if (nameLine) {
        tokens.add(nameLine);
    }

    const sourceHasAddressTerms = /\b(address|city|residence|living in|located in|location)\b/i.test(immutableBlock);
    const sourceHasResidenceTerms = /\b(city|residence|living in|located in)\b/i.test(immutableBlock);

    const educationCoreFacts = extractImmutableEducationCoreFacts(markdown);

    return {
        requiredTokens: Array.from(tokens).filter((t) => !!t),
        sourceHasAddressTerms,
        sourceHasResidenceTerms,
        educationCoreFacts
    };
}

function validatePersonalIntegrityOrThrow(
    html: string,
    guardrails: PersonalGuardrails,
    strictLinkIntegrity: boolean
): void {
    const missingTokens = guardrails.requiredTokens.filter((token) => !html.includes(token));
    if (missingTokens.length > 0) {
        const msg = `Generated HTML is missing immutable personal/contact tokens: ${missingTokens.join(', ')}`;
        if (strictLinkIntegrity) {
            throw new Error(msg);
        }
        process.stderr.write(`[WARN] ${msg}\n`);
    }

    if (!guardrails.sourceHasAddressTerms) {
        const hasInjectedAddressTerms = /\b(address|city|residence|living in|located in)\b\s*[:\-]?/i.test(html);
        if (hasInjectedAddressTerms) {
            const msg = 'Generated HTML appears to inject new personal location/address metadata that is not in baseline profile.';
            if (strictLinkIntegrity) {
                throw new Error(msg);
            }
            process.stderr.write(`[WARN] ${msg}\n`);
        }
    }

    if (!guardrails.sourceHasResidenceTerms) {
        const hasResidenceClaim = /\b(lives in|living in|resides in|based in)\b/i.test(html);
        if (hasResidenceClaim) {
            const msg = 'Generated HTML appears to add a residence/city claim that is not present in baseline profile.';
            if (strictLinkIntegrity) {
                throw new Error(msg);
            }
            process.stderr.write(`[WARN] ${msg}\n`);
        }
    }

    const canonicalHtml = canonicalizeFactText(html);
    const missingEducationFacts = guardrails.educationCoreFacts.filter((fact) => !hasEducationFactMatch(canonicalHtml, fact));
    if (missingEducationFacts.length > 0) {
        const msg = `Generated HTML is missing immutable education core facts: ${missingEducationFacts.join(', ')}`;
        if (strictLinkIntegrity) {
            throw new Error(msg);
        }
        process.stderr.write(`[WARN] ${msg}\n`);
    }
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

function validateLockedLinksInHtmlOrThrow(
    html: string,
    lockedLinks: LockedLink[],
    strictLinkIntegrity: boolean
): void {
    if (!lockedLinks.length) {
        return;
    }

    const missing = lockedLinks.filter((item) => !html.includes(item.url));
    if (missing.length > 0) {
        const missingSummary = missing.map((item) => `${item.label}: ${item.url}`).join(', ');
        const message = `Generated HTML is missing locked profile links: ${missingSummary}`;
        if (strictLinkIntegrity) {
            throw new Error(message);
        }
        process.stderr.write(`[WARN] ${message}\n`);
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
    modelOverride?: string,
    strictLinkIntegrity: boolean = true
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
    const profileWithPlaceholders = applyLinkPlaceholdersToText(profile.content, lockedLinks);
    const lockedLinksInstruction = buildLockedLinksInstruction(lockedLinks);
    const immutablePersonalBlock = extractImmutablePersonalBlock(profile.content);
    const immutableEducationSection = extractSection(profile.content, 'Education');
    const personalGuardrails = buildPersonalGuardrails(profile.content);

    const prompt = `
    TASK: Generate a high-impact, 1-page HTML resume using Gemini 2.5 Pro capabilities.
    USER_PROFILE: ${profileWithPlaceholders}
    TARGET_JOB: ${job.title} - ${job.description}

    CONSTRAINTS for Automation:
    - Use inline CSS for layout stability.
    - Ensure a professional, modern look.
    - Output MUST be valid HTML5.
    - Avoid external JS; minimize external web fonts to ensure fast PDF rendering.

    LINK INTEGRITY CONSTRAINTS:
    ${lockedLinksInstruction}

    IMMUTABLE PERSONAL DATA BLOCK (DO NOT ALTER VALUES):
    ${immutablePersonalBlock}

    IMMUTABLE EDUCATION FACTS (DO NOT ALTER PROGRAM/INSTITUTION/YEARS/CAMPUS FACTS):
    ${immutableEducationSection}

    EDIT SCOPE CONSTRAINTS:
    - You may tailor ONLY professional content sections (summary, skills, experience, projects, education wording).
    - You MUST keep identity and contact facts unchanged (name, phone, email, links).
    - Do NOT change factual entities in education (program/degree names, institution names, years, campus/city in education lines).
    - Do NOT add new personal identifiers (city/residence/address, age, marital status, ID, nationality) unless explicitly present above.
    - Keep all link placeholders exactly unchanged (e.g. __LOCKED_LINK_1__).

    OUTPUT BUDGET CONSTRAINTS (for one-page reliability):
    - Professional Summary: max 3 bullets, each <= 18 words.
    - Technical Skills: max 5 grouped bullets.
    - Work Experience: max 2 roles, each role max 2 bullets, each bullet <= 20 words.
    - Projects: max 2 project bullets total.
    - Education: preserve core facts, keep concise, max 1 supporting bullet per education entry.
    - Keep total density suitable for exactly one A4 page.

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
        const restoredHtml = restoreLinkPlaceholdersInText(parsed.resumeHtml, lockedLinks);
        validateLockedLinksInHtmlOrThrow(restoredHtml, lockedLinks, strictLinkIntegrity);
        validatePersonalIntegrityOrThrow(restoredHtml, personalGuardrails, strictLinkIntegrity);
        return { ...parsed, resumeHtml: restoredHtml };
    });
};

export const refineResume = async (
    currentHtml: string,
    job: JobDetails,
    profile: UserProfile,
    apiKey: string,
    modelOverride?: string,
    strictLinkIntegrity: boolean = true
): Promise<string> => {
    if (!apiKey) throw new Error("API Key missing.");

    const ai = new GoogleGenAI({ apiKey });
    const judgeModel = resolveAllowedModelOrThrow(modelOverride);
    const lockedLinks = extractLockedLinksFromMarkdown(profile.content);
    const profileWithPlaceholders = applyLinkPlaceholdersToText(profile.content, lockedLinks);
    const lockedLinksInstruction = buildLockedLinksInstruction(lockedLinks);
    const personalGuardrails = buildPersonalGuardrails(profile.content);
    const immutablePersonalBlock = extractImmutablePersonalBlock(profile.content);
    const immutableEducationSection = extractSection(profile.content, 'Education');
    const htmlWithPlaceholders = applyLinkPlaceholdersToText(currentHtml, lockedLinks);
    const prompt = `Surgically refine this Resume HTML to perfectly match the JD keywords: ${job.description}.

Current HTML: ${htmlWithPlaceholders}

SOURCE PROFILE: ${profileWithPlaceholders}

CRITICAL CONSTRAINTS:
${lockedLinksInstruction}
IMMUTABLE PERSONAL DATA BLOCK:
${immutablePersonalBlock}
IMMUTABLE EDUCATION FACTS:
${immutableEducationSection}
- Keep the existing structure and formatting style unless a change is required for factual correctness or ATS relevance.
- Refine ONLY professional sections (summary/skills/experience/projects/education wording).
- Preserve identity/contact values exactly; do not add city/address/residence unless explicitly present in source profile.
- Do NOT change factual entities in education (program/degree names, institution names, years, campus/city in education lines).
- Preserve existing links exactly when present and never replace a user-specific link with a generic home page.
- Keep all link placeholders exactly unchanged (e.g. __LOCKED_LINK_1__).
- Never add fabricated or exaggerated claims.
- Keep one-page density: remove redundancy, merge overlapping bullets, prioritize job-relevant content.`;

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
        const resultHtmlWithPlaceholders = htmlMatch ? htmlMatch[0] : cleanedHtml.replace(/^\s*```html/, '').replace(/\s*```$/, '').trim();
        const resultHtml = restoreLinkPlaceholdersInText(resultHtmlWithPlaceholders, lockedLinks);
        validateLockedLinksInHtmlOrThrow(resultHtml, lockedLinks, strictLinkIntegrity);
        validatePersonalIntegrityOrThrow(resultHtml, personalGuardrails, strictLinkIntegrity);
        return resultHtml;
    });
};

export const enforceOnePageResume = async (
    currentHtml: string,
    job: JobDetails,
    profile: UserProfile,
    apiKey: string,
    modelOverride?: string,
    strictLinkIntegrity: boolean = true
): Promise<string> => {
    if (!apiKey) throw new Error("API Key missing.");

    const ai = new GoogleGenAI({ apiKey });
    const model = resolveAllowedModelOrThrow(modelOverride);
    const lockedLinks = extractLockedLinksFromMarkdown(profile.content);
    const profileWithPlaceholders = applyLinkPlaceholdersToText(profile.content, lockedLinks);
    const lockedLinksInstruction = buildLockedLinksInstruction(lockedLinks);
    const personalGuardrails = buildPersonalGuardrails(profile.content);
    const immutablePersonalBlock = extractImmutablePersonalBlock(profile.content);
    const immutableEducationSection = extractSection(profile.content, 'Education');
    const htmlWithPlaceholders = applyLinkPlaceholdersToText(currentHtml, lockedLinks);

    const prompt = `Compress this resume HTML so it reliably fits one A4 page while preserving factual integrity.

Current HTML:
${htmlWithPlaceholders}

Job context:
${job.description}

SOURCE PROFILE:
${profileWithPlaceholders}

CRITICAL CONSTRAINTS:
${lockedLinksInstruction}
IMMUTABLE PERSONAL DATA BLOCK:
${immutablePersonalBlock}
IMMUTABLE EDUCATION FACTS:
${immutableEducationSection}
- Keep all immutable facts unchanged.
- Do not add city/residence/address unless explicitly present in source profile.
- Keep all locked placeholders unchanged (e.g. __LOCKED_LINK_1__).
- Keep professional impact but compress wording, merge bullets, remove redundancy, and prioritize job-relevant content.
- Compaction budget:
    - Summary max 2 bullets.
    - Experience max 2 bullets per role.
    - Projects max 2 bullets total.
    - Education core facts must remain but narrative text should be minimal.
- Output ONLY valid raw HTML.`;

    return await withRetry(async () => {
        const response = await ai.models.generateContent({
            model,
            contents: prompt,
            config: {
                responseMimeType: "text/plain",
                thinkingConfig: { thinkingBudget: 4096 },
                systemInstruction: "You are an expert resume editor. Optimize layout/content density to fit exactly one A4 page while preserving all immutable facts and locked links.",
            }
        });

        const cleanedHtml = response.text || "";
        const htmlMatch = cleanedHtml.match(/(?:<!DOCTYPE html>|<html)[\s\S]*<\/html>/i);
        const resultHtmlWithPlaceholders = htmlMatch ? htmlMatch[0] : cleanedHtml.replace(/^\s*```html/, '').replace(/\s*```$/, '').trim();
        const resultHtml = restoreLinkPlaceholdersInText(resultHtmlWithPlaceholders, lockedLinks);

        validateLockedLinksInHtmlOrThrow(resultHtml, lockedLinks, strictLinkIntegrity);
        validatePersonalIntegrityOrThrow(resultHtml, personalGuardrails, strictLinkIntegrity);
        return resultHtml;
    });
};