import { GoogleGenAI, Type, type Schema } from "@google/genai";
import { UserProfile, JobDetails, GeneratedAssets } from "./types";

const GENERATOR_MODEL = 'gemini-2.5-pro';
const JUDGE_MODEL = 'gemini-2.5-pro';

const resumeSchemaPart = {
  type: Type.STRING,
  description: "A complete, stand-alone HTML document string for the tailored resume. It MUST be designed to fit exactly on one A4 page. It must include internal CSS for professional styling, layout (columns/grids), and print optimization."
};

export const generateApplicationAssets = async (
  profile: UserProfile,
  job: JobDetails,
  apiKey: string
): Promise<GeneratedAssets> => {
  if (!apiKey) {
    throw new Error("API Key is missing. Please set GEMINI_API_KEY.");
  }

  const ai = new GoogleGenAI({ apiKey });

  // Base cost for Resume (Layout + Content): 4096 tokens
  let thinkingBudget = 4096;

  console.log(`Gemini: Generating Draft using ${GENERATOR_MODEL} with Thinking Budget: ${thinkingBudget}...`);

  const dynamicSchema: Schema = {
    type: Type.OBJECT,
    properties: {
      resumeHtml: resumeSchemaPart
    },
    required: ["resumeHtml"]
  };

  const prompt = `
    You are an expert executive career coach and professional resume writer.
    
    I will provide you with a candidate's raw profile (in Markdown format) and a target Job Description.
    
    Your goal is to "power-up" this candidate's application by generating a comprehensive custom Resume.
    
    ### 1. The Tailored Resume (HTML)
    **CRITICAL REQUIREMENT**: The resume must be designed to fit on **EXACTLY ONE A4 PAGE** (210mm x 297mm). 
    
    **Content Strategy (STRICT BREVITY):**
    - **Summary**: Maximum 2-3 lines.
    - **Experience**: 
      - Focus strictly on the 2-3 most relevant roles. 
      - Limit these roles to 3-4 high-impact bullet points each.
      - For older or less relevant roles, use a single line (Title, Company, Dates) or omit them entirely.
    - **Skills**: Use a compact comma-separated list or a dense grid sidebar.
    - **IF CONTENT IS TOO LONG, CUT IT.** Do not allow spillover to page 2.
    
    **Technical/CSS Instructions:**
    - Output a full HTML document with \`<html>\`, \`<head>\`, and \`<body>\`.
    - Use internal CSS (\`<style>\`).
    - **Print Optimization**: 
        - Include \`@page { size: A4; margin: 0; }\`
        - Include \`-webkit-print-color-adjust: exact; print-color-adjust: exact;\` to ensure backgrounds print.
        - Ensure text is black (#000) or very dark grey for legibility.
    - **Page Container**: The main wrapper div MUST have:
      - \`width: 210mm;\`
      - \`height: 296mm;\` (Just under 297mm to be safe)
      - \`padding: 12mm;\` (Maximized space)
      - \`margin: 0 auto;\`
      - \`box-sizing: border-box;\`
      - \`overflow: hidden;\` (Prevents visual spillover)
      - \`background: white;\`
    - **Typography**: 
      - Body text: 9pt to 10.5pt (Keep it small but readable).
      - Headings: 12pt to 16pt.
      - Line-height: 1.2 to 1.3 (Tight).
    - **Layout**: Use a 2-column layout (Sidebar approx 30%, Main 70%) to make efficient use of vertical space.
    - **NO MARKDOWN**: Do NOT use markdown syntax (like **bold** or *italics*) inside the HTML. Use valid HTML tags only (<strong>, <em>).

    ---
    **Candidate Profile (Markdown):**
    ${profile.content}

    **Target Job Title:**
    ${job.title}

    **Target Job Description:**
    ${job.description}
    ---
  `;

  try {
    const response = await ai.models.generateContent({
      model: GENERATOR_MODEL,
      contents: prompt,
      config: {
        responseMimeType: "application/json",
        responseSchema: dynamicSchema,
        thinkingConfig: { thinkingBudget: thinkingBudget },
        systemInstruction: "You are a world-class career strategist. You prioritize concise, high-impact communication. You NEVER produce a resume longer than 1 page. You never use Markdown syntax in plain text fields. You never use Markdown syntax inside HTML code.",
      },
    });

    const text = response.text;
    if (!text) {
      throw new Error("No response received from Gemini.");
    }

    const parsed = JSON.parse(text) as GeneratedAssets;
    console.log("Gemini: Draft Complete");
    return parsed;
  } catch (error) {
    console.error("Gemini API Error:", error);
    throw error;
  }
};

export const refineResume = async (
  currentHtml: string,
  job: JobDetails,
  profile: UserProfile,
  apiKey: string
): Promise<string> => {
  if (!apiKey) throw new Error("API Key is missing. Please set GEMINI_API_KEY.");

  const ai = new GoogleGenAI({ apiKey });

  // High thinking budget for code auditing and repair
  const JUDGE_THINKING_BUDGET = 4096;

  console.log(\`Gemini: Starting Surgical Refinement using \${JUDGE_MODEL} (Budget: \${JUDGE_THINKING_BUDGET})...\`);

    const prompt = \`
        You are a Senior Technical Recruiter and Quality Assurance Specialist acting as a "Judge" for a resume application.
        
        Your Goal: Surgically repair and improve the provided Resume HTML.
        
        **INPUT DATA:**
        1. **The Candidate's Master Profile**: To verify facts.
        2. **The Target Job Description**: To ensure keyword alignment.
        3. **The DRAFT Resume HTML**: The document you must fix.

        **YOUR AUDIT CHECKLIST (Fix these issues immediately):**
        1. **Integrity Check**: Does the HTML end abruptly? If so, complete the sentence and close all tags (</body>, </html>) properly.
        2. **Keyword Injection**: The Draft might have missed specific hard skills mentioned in the JD. Surgically replace generic terms with specific keywords from the JD where truthful.
        3. **Fluff Elimination (CRITICAL)**: Scan for ambiguous fluff like "results-oriented," "hard worker," "responsible for," "proven track record," or "seasoned professional." DELETE these phrases or replace them with specific actions/results. If a sentence adds no concrete value, remove it entirely.
        4. **Formatting**: Ensure the layout is preserved. Ensure strict one-page fit (A4). 
        5. **Hallucination Check**: Ensure the Draft didn't invent experience not present in the Master Profile.
        6. **Markdown Scrubbing**: Scan for and REMOVE any markdown syntax like **bold** or *italics* or ### headers inside the HTML. Replace them with valid HTML tags (<strong>, <em>, <h3>) or remove them if they break the code.
        
        **OUTPUT:**
        Return ONLY the corrected, valid, full HTML string. Do not wrap it in markdown code blocks. Do not add explanations. Just the code.
        
        ---
        **Master Profile:**
        \${profile.content}
        
        **Job Description:**
        \${job.description}
        
        **DRAFT HTML TO FIX:**
        \${currentHtml}
        ---
    \`;

    try {
        const response = await ai.models.generateContent({
            model: JUDGE_MODEL, 
            contents: prompt,
            config: {
                responseMimeType: "text/plain", 
                thinkingConfig: { thinkingBudget: JUDGE_THINKING_BUDGET },
            }
        });

        let cleanedHtml = response.text || "";
        
        // STRICT CLEANUP: Extract only the HTML part if the model chatted
        const htmlMatch = cleanedHtml.match(/(?:<!DOCTYPE html>|<html)[\\s\\S]*<\\/html>/i);
        
        if (htmlMatch) {
            console.log("Gemini: Extracted valid HTML from response.");
            cleanedHtml = htmlMatch[0];
        } else {
             // Fallback cleanup if regex fails but markdown blocks exist
             cleanedHtml = cleanedHtml.replace(/^\\s*\`\`\`html/, '').replace(/\\s*\`\`\`$/, '').trim();
        }

        console.log("Gemini: Refinement Complete");
        return cleanedHtml;

    } catch (error) {
        console.error("Refinement Error:", error);
        return currentHtml;
    }
};