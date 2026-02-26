#!/usr/bin/env node

import { Command } from 'commander';
import * as fs from 'fs';
import * as path from 'path';
import 'dotenv/config'; // loads .env variables, including GEMINI_API_KEY
import puppeteer from 'puppeteer';
import { generateApplicationAssets, refineResume } from './gemini';

const program = new Command();

program
    .name('careerforge')
    .description('CareerForge CLI to generate customized CV PDFs from profile and job descriptions')
    .version('1.0.0')
    .requiredOption('-p, --profile <path>', 'Path to the user profile markdown file')
    .requiredOption('-j, --job <path>', 'Path to the job description text file')
    .option('-o, --out <path>', 'Output path for the generated PDF', 'resume.pdf')
    .option('-t, --theme <name>', 'Theme to apply (original, modern, serif, minimal)', 'original')
    .parse(process.cwd());

const THEMES: Record<string, { css: string }> = {
    original: { css: '' },
    modern: {
        css: \`
      @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&display=swap');
      body { font-family: 'Inter', sans-serif !important; color: #1e293b !important; }
      h1 { color: #1e40af !important; letter-spacing: -0.5px; }
      h2, h3 { color: #2563eb !important; }
      .sidebar { background-color: #f8fafc !important; border-right: none !important; }
      ul li::before { color: #3b82f6 !important; }
      a { color: #2563eb !important; }
    \` 
  },
  serif: { 
    css: \`
      @import url('https://fonts.googleapis.com/css2?family=Merriweather:ital,wght@0,300;0,400;0,700;1,400&display=swap');
      body { font-family: 'Merriweather', serif !important; color: #0f172a !important; }
      h1 { font-family: 'Merriweather', serif !important; text-transform: uppercase; border-bottom: 2px solid #0f172a; padding-bottom: 0.5rem; letter-spacing: 1px; }
      h2 { color: #334155 !important; font-family: 'Merriweather', serif !important; font-style: italic; border-bottom: 1px solid #e2e8f0; }
      h3 { font-family: 'Merriweather', serif !important; }
      .sidebar { background-color: transparent !important; border-right: 1px solid #e2e8f0 !important; }
    \` 
  },
  minimal: { 
    css: \`
      @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&display=swap');
      body { font-family: 'JetBrains Mono', monospace !important; font-size: 9pt !important; color: #000 !important; }
      h1 { text-transform: lowercase; color: #000 !important; letter-spacing: -1px; }
      h2 { text-transform: uppercase; font-size: 10pt !important; background: #000; color: #fff !important; padding: 2px 6px; display: inline-block; }
      h3 { font-weight: 700 !important; }
      .sidebar { border-right: 1px dashed #94a3b8 !important; }
      ul { list-style-type: square !important; }
    \` 
  }
};

const main = async () => {
    const options = program.opts();
    const apiKey = process.env.GEMINI_API_KEY;

    if (!apiKey) {
        console.error("Error: GEMINI_API_KEY environment variable is not set.");
        process.exit(1);
    }

    try {
        console.log("Reading input files...");
        const profileContent = fs.readFileSync(path.resolve(options.profile), 'utf-8');
        const jobContent = fs.readFileSync(path.resolve(options.job), 'utf-8');

        // Note: For simplicity, we just pass the raw job content as description.
        // A more advanced integration might parse title/company.
        const jobDetails = {
            title: "Unknown",
            company: "Unknown",
            description: jobContent
        };

        const profile = { content: profileContent };

        console.log("Generating Resume CV HTML...");
        const generated = await generateApplicationAssets(profile, jobDetails, apiKey);
        
        console.log("Surgically refining HTML...");
        const refinedHtml = await refineResume(generated.resumeHtml, jobDetails, profile, apiKey);

        let finalHtml = refinedHtml;

        // Apply theme if selected
        const themeOption = (options.theme as string).toLowerCase();
        if (themeOption !== 'original' && THEMES[themeOption]) {
            console.log(\`Applying theme: \${themeOption}\`);
            finalHtml = finalHtml.replace(
                '</head>', 
                \`<style>\${THEMES[themeOption].css}</style></head>\`
            );
        }

        console.log("Converting HTML to PDF using Puppeteer...");
        const browser = await puppeteer.launch({ headless: 'new' });
        const page = await browser.newPage();
        
        await page.setContent(finalHtml, { waitUntil: 'networkidle0' });

        const outputPath = path.resolve(options.out);
        await page.pdf({
            path: outputPath,
            format: 'A4',
            printBackground: true,
            margin: { top: '0', right: '0', bottom: '0', left: '0' }
        });

        await browser.close();

        console.log(\`✅ Done! Resume successfully generated at: \${outputPath}\`);

    } catch (e: any) {
        console.error("An error occurred during generation:", e.message);
        process.exit(1);
    }
};

main();
