#!/usr/bin/env node

/**
 * cli.ts
 * CAREERFORGE CLI (v2026.03.05)
 * English Documentation:
 * 1. Upgraded to Gemini 2.5 Pro for advanced tailoring and logic.
 * 2. Implemented Stage-based logging ([STAGE:NAME]) for Telegram integration.
 * 3. Enhanced Human-Like interaction: increased delays and multi-stage scrolling.
 * 4. Added pre-emptive throttling to prevent API 429 errors.
 */

import { Command } from 'commander';
import * as fs from 'fs';
import * as path from 'path';
import 'dotenv/config';
import puppeteer from 'puppeteer';
import type { Page } from 'puppeteer';
import { enforceOnePageResume, generateApplicationAssets, refineResume } from './gemini';

const program = new Command();

// --- HELPERS ---

/**
 * Generates a non-blocking delay with significant randomization to mimic human behavior.
 * Added larger jitter to accommodate Gemini 2.5 Pro pacing.
 */
const humanDelay = (ms: number) => {
    const jitter = Math.random() * 1500; // Up to 1.5s additional jitter
    return new Promise(res => setTimeout(res, ms + jitter));
};

/**
 * Prevents overwriting existing resumes by appending a timestamp.
 */
const getSafeOutputPath = (targetPath: string): string => {
    const absolutePath = path.resolve(targetPath);
    if (!fs.existsSync(absolutePath)) return absolutePath;

    const dir = path.dirname(absolutePath);
    const ext = path.extname(absolutePath);
    const baseName = path.basename(absolutePath, ext);
    const timestamp = new Date().getTime();

    const newPath = path.join(dir, `${baseName}_${timestamp}${ext}`);
    console.log(`⚠️ Warning: File already exists. Redirecting to: ${newPath}`);
    return newPath;
};

/**
 * Simulates a human mouse click with jitter, smooth movement, and realistic timing.
 */
async function humanClick(page: any, selector: string) {
    const element = await page.waitForSelector(selector, { visible: true, timeout: 8000 });
    const box = await element.boundingBox();
    if (box) {
        // Randomize target point within the button
        const x = box.x + box.width * (0.2 + Math.random() * 0.6);
        const y = box.y + box.height * (0.2 + Math.random() * 0.6);

        // Move cursor smoothly
        await page.mouse.move(x, y, { steps: 15 });
        await humanDelay(800);
        await page.mouse.down();
        await humanDelay(200); // Click duration jitter
        await page.mouse.up();
    }
}

// --- CORE ACTIONS ---

/**
 * Automated browser application flow with stage-based reporting.
 */
const applyToJob = async (pdfPath: string, jobUrl: string) => {
    console.log(`[STAGE:START] Initiating application process...`);
    console.log(`🔗 Target URL: ${jobUrl}`);
    console.log(`📄 Using PDF: ${pdfPath}`);

    // Pre-emptive pause before launching to ensure API/System readiness
    await humanDelay(3000);

    const browser = await puppeteer.launch({
        headless: false,
        defaultViewport: null,
        args: [
            '--disable-blink-features=AutomationControlled',
            '--start-maximized'
        ]
    });

    const [page] = await browser.pages();

    try {
        console.log(`[STAGE:NAVIGATE] Opening browser and navigating to site...`);
        await page.goto(jobUrl, { waitUntil: 'networkidle2' });

        // Simulate human "reading" behavior with staggered scrolling
        console.log(`[STAGE:SCROLLING] Reading job description...`);
        await humanDelay(3000);
        await page.evaluate(() => window.scrollBy(0, 400 + Math.random() * 200));
        await humanDelay(2000);
        await page.evaluate(() => window.scrollBy(0, -150)); // Slight scroll back up like a reader
        await humanDelay(1500);

        const applySelectors = [
            'button.jobs-apply-button',
            'button[aria-label*="Apply"]',
            'button[aria-label*="הגש"]',
            '.apply-button'
        ];

        console.log(`[STAGE:MODAL] Searching for application trigger...`);
        let found = false;
        for (const selector of applySelectors) {
            try {
                await humanClick(page, selector);
                found = true;
                break;
            } catch { continue; }
        }

        if (found) {
            console.log("[STAGE:WAIT] Apply modal detected. Awaiting manual file upload...");
            await humanDelay(2000);

            console.log(`\n⚠️ ACTION REQUIRED:`);
            console.log(`1. Ensure you are on the "Resume Upload" step.`);
            console.log(`2. Upload the file from: ${pdfPath}`);
            console.log(`3. Press ENTER in this terminal to signal readiness for final review.`);

            // Terminal Wait for User Confirmation
            await new Promise(resolve => process.stdin.once('data', resolve));

            console.log("🖱️ Manual signal received. Proceeding with final interaction checks...");
        }
    } catch (err: any) {
        console.error(`[STAGE:ERROR] Application flow failed: ${err.message}`);
    }
};

const THEMES: Record<string, { css: string }> = {
    original: { css: '' },
    modern: { css: `@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;700&display=swap'); body { font-family: 'Inter', sans-serif !important; }` },
    serif: { css: `@import url('https://fonts.googleapis.com/css2?family=Merriweather&display=swap'); body { font-family: 'Merriweather', serif !important; }` },
    minimal: { css: `body { font-family: monospace !important; font-size: 10pt !important; }` }
};

const mmToPx = (mm: number): number => (mm * 96) / 25.4;
const MAX_ONE_PAGE_COMPACTION_ATTEMPTS = 2;

async function estimateA4PageCount(page: Page): Promise<number> {
    await page.emulateMediaType('print');
    const printableHeightPx = mmToPx(297 - 20); // assume ~10mm top + ~10mm bottom margin
    const contentHeight = await page.evaluate(() => {
        const body = document.body;
        const html = document.documentElement;
        return Math.max(
            body?.scrollHeight || 0,
            body?.offsetHeight || 0,
            html?.clientHeight || 0,
            html?.scrollHeight || 0,
            html?.offsetHeight || 0
        );
    });

    return Math.max(1, Math.ceil(contentHeight / printableHeightPx));
}

// --- CLI COMMANDS ---

program
    .name('careerforge')
    .version('1.1.0')
    .description('CareerForge CLI - Gemini 2.5 Pro Optimized');

// Command: Generate PDF
program
    .command('generate')
    .description('Generate a customized CV PDF using Gemini 2.5 Pro')
    .requiredOption('-p, --profile <path>', 'Path to user profile markdown')
    .requiredOption('-j, --job <path>', 'Path to job description text file')
    .option('-o, --out <path>', 'Output path for PDF', 'resume.pdf')
    .option('-t, --theme <name>', 'Theme (original, modern, serif, minimal)', 'modern')
    .option('-m, --model <id>', 'Model override (must be in allowlist, e.g. google/gemini-2.5-pro)')
    .option('--no-strict-link-integrity', 'Allow generation to continue even when locked profile links are missing in output')
    .option('--no-strict-one-page', 'Allow PDF generation even if rendered CV exceeds one A4 page')
    .action(async (options) => {
        const apiKey = process.env.GEMINI_API_KEY || "GATEWAY_MANAGED";
        try {
            console.log("[STAGE:START] Reading profile and job data...");
            const profileContent = fs.readFileSync(path.resolve(options.profile), 'utf-8');
            const jobContent = fs.readFileSync(path.resolve(options.job), 'utf-8');

            const jobDetails = {
                title: "AI Analysis in Progress",
                company: "Extracted via Gemini 2.5",
                description: jobContent
            };
            const profile = { content: profileContent };
            const selectedModel = options.model ? String(options.model).trim() : undefined;
            const strictLinkIntegrity = options.strictLinkIntegrity !== false;
            const strictOnePage = options.strictOnePage !== false;

            console.log(`🚀 Gemini is crafting your executive resume${selectedModel ? ` (model: ${selectedModel})` : ''}${strictLinkIntegrity ? ' [strict-link-integrity]' : ' [link-integrity-warn-only]'}${strictOnePage ? ' [strict-one-page]' : ' [one-page-warn-only]'}...`);
            const generated = await generateApplicationAssets(profile, jobDetails, apiKey, selectedModel, strictLinkIntegrity);

            console.log("🛠️ Performing surgical refinement for ATS optimization...");
            const refinedHtml = await refineResume(generated.resumeHtml, jobDetails, profile, apiKey, selectedModel, strictLinkIntegrity);

            let finalHtml = refinedHtml;
            const theme = options.theme.toLowerCase();
            if (THEMES[theme]) {
                finalHtml = finalHtml.replace('</head>', `<style>${THEMES[theme].css}</style></head>`);
            }

            const browser = await puppeteer.launch({ headless: true });
            const page = await browser.newPage();
            await page.setContent(finalHtml, { waitUntil: 'networkidle0' });

            let estimatedPageCount = await estimateA4PageCount(page);
            if (estimatedPageCount > 1 && strictOnePage) {
                for (let attempt = 1; attempt <= MAX_ONE_PAGE_COMPACTION_ATTEMPTS && estimatedPageCount > 1; attempt++) {
                    console.log(`📉 One-page guardrail: compaction attempt ${attempt}/${MAX_ONE_PAGE_COMPACTION_ATTEMPTS}...`);
                    finalHtml = await enforceOnePageResume(finalHtml, jobDetails, profile, apiKey, selectedModel, strictLinkIntegrity);
                    await page.setContent(finalHtml, { waitUntil: 'networkidle0' });
                    estimatedPageCount = await estimateA4PageCount(page);
                }
            }

            if (estimatedPageCount > 1) {
                const msg = `Rendered CV exceeds one A4 page (estimated pages: ${estimatedPageCount}) after compaction attempts.`;
                if (strictOnePage) {
                    await browser.close();
                    throw new Error(msg);
                }
                console.warn(`⚠️ ${msg}`);
            }

            const finalOutputPath = getSafeOutputPath(options.out);
            await page.pdf({
                path: finalOutputPath,
                format: 'A4',
                printBackground: true
            });

            await browser.close();
            console.log(`✅ Success! CV saved to: ${finalOutputPath}`);
        } catch (e: any) {
            console.error(`❌ Generation failed: ${e.message}`);
        }
    });

// Command: Apply to Job
program
    .command('apply')
    .description('Perform throttled, human-like job application')
    .requiredOption('-f, --file <path>', 'Path to the resume PDF')
    .requiredOption('-u, --url <url>', 'Target job URL')
    .action(async (options) => {
        await applyToJob(path.resolve(options.file), options.url);
    });

program.parse(process.argv);

/**
 * 2026.03.05 LOG:
 * Added [STAGE:X] tags to all async flows to allow OpenClaw Telegram integration.
 * Optimized humanClick for better element targeting in dynamic SPAs.
 */