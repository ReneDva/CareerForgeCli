# 📚 CandleKeep Agent Command Pack

## 🎯 מטרת הפקודות
לאפשר לסוכן:
- לגשת לספרייה שלו ב-CandleKeep
- לקרוא ספרים
- לשלוף מידע מדויק
- להשתמש בתוכן כדי לבצע משימות פיתוח, אבטחה, פרומפטינג ועוד

Trigger this flow automatically when user phrasing is similar to:
- "consult my books about [topic]"
- "research [topic] using candlekeep"
- "what do my books say about [topic]?"
- "use candlekeep books to review my code"

---

## 🧠 פקודות בסיסיות

### 🔐 Authentication

- `ck auth login`
- `ck auth logout`
- `ck auth whoami`

### 📚 Library Management

- `ck items list`
- `ck items add <file>`
- `ck items remove <id>`

### 📖 Reading

- `ck items read <id>`
- `ck items read "<id>:1-5"`
- `ck items read "<id>:all"`
- `ck items toc <id>`

### 🧾 Output Options

- `ck items list --json`
- `ck auth whoami --json`

---

## 📘 הנחיות לסוכן: איך להשתמש בפקודות כדי לקרוא ספרים

```text
You have access to CandleKeep.
Use the following workflow whenever you need domain knowledge:

1. List available books:
   ck items list --json

2. Identify the relevant book by title or keywords.

3. Read the table of contents:
   ck items toc <id>

4. Read specific pages or sections:
   ck items read "<id>:1-20"

5. Extract insights, summarize them, and apply them to the task.

Always cite which book and which pages you used.
```

---

## 📚 רשימת הספרים שהסוכן צריך להשתמש בהם

```text
Use the following books from CandleKeep whenever relevant:

- Anthropic's guide to building effective agents
- The complete guide to building Claude skills
- Google Gemini prompting best practices
- OpenAI prompting best practices
- React / Vercel frontend engineering guidelines
- Supabase Postgres best practices
- OWASP security testing guide

When solving a task, search these books first.
Read the relevant sections and apply the principles directly.
```

---

## 🤖 הנחיה מלאה לשימוש ב-VS Code Copilot Agent

```text
You have access to CandleKeep.
Search for the following books and use them as your primary knowledge base:

- Anthropic's guide to building effective agents
- The complete guide to building Claude skills
- Google Gemini prompting best practices
- OpenAI prompting best practices
- React / Vercel frontend engineering guidelines
- Supabase Postgres best practices
- OWASP security testing guide

Workflow:
1. Run: ck items list --json
2. Locate the relevant book.
3. Run: ck items toc <id>
4. Read the needed sections using:
   ck items read <id> --pages "X-Y"
5. Extract insights and apply them to the task.
6. Cite which book and pages you used.

Always operate autonomously and retrieve the knowledge yourself.
```
