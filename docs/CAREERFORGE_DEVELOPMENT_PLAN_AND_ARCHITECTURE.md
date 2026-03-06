# CareerForge — Development Plan & Recommended Architecture

_Last updated: 2026-03-06_

מסמך זה מיועד לשימוש פיתוח שוטף (Assistant + User) ולתיעוד מוצרי/טכני של המערכת.

---

## 1) מטרות המערכת

1. למצוא משרות רלוונטיות בלבד (מיקום + ניסיון + מילות מפתח).
2. לייצר קורות חיים מותאמים לכל משרה בצורה אמינה וחסכונית במשאבים.
3. לאפשר **אישור ידני חובה** על כל קובץ CV לפני הגשה.
4. לשמור היסטוריית גרסאות CV + ארכיון קבצים שהוגשו בפועל.
5. לשמור סטטוס משרה ברור מקצה לקצה (הוגש / לא הוגש / נכשל + סיבה).
6. למנוע חסימות באתרי יעד (במיוחד LinkedIn) באמצעות מצב הגשה חצי-ידני כברירת מחדל.
7. להגדיר מקור אמת קבוע ל-CV בסיסי: `profile.md` כקובץ Markdown גנרי (לא PDF), שממנו נגזרות גרסאות PDF מותאמות.

---

## 2) עקרונות תכנון

- **Human-in-the-loop first**: אין Apply ללא אישור מפורש.
- **Reliability over magic**: תהליכים דטרמיניסטיים, מעברי סטטוס חוקיים בלבד.
- **Low-cost AI path**: שימוש מבוקר במודל, queue חד-ערוצי, Retry רק היכן שצריך.
- **Auditability**: לכל משרה יש Trace מלא (הודעות, גרסאות CV, תוצאת Apply).
- **Progressive automation**: קודם יציבות, אחר כך אוטומציה עמוקה.

---

## 3) תוכנית עבודה שלבית (כולל בדיקות בכל שלב)

## שלב 0 — Baseline & Safety

### מטרות
- להקפיא מצב נוכחי, להבטיח סודות לא דולפים, להגדיר סביבת בדיקות.

### משימות
- לוודא `.env` לא נכלל בגיט, לבצע rotation לסודות במקרה חשיפה.
- ליצור סביבת test data: `tests/fixtures/jobs/*.json`.
- להוסיף `docs/OPERATIONS.md` עם runbook בסיסי.

### בדיקות
- `git status` נקי מסודות.
- בדיקה ידנית: אין שום ערך סודי בלוגים.

### Exit Criteria
- אפשר להריץ flow מקומי בטוח ללא חשש דליפת מפתחות.

---

## שלב 1 — תיקון מנוע סינון משרות

### מטרות
- לעצור משרות לא רלוונטיות (מיקום/ניסיון) לפני שלב ההתראות.

### משימות
- לתקן `job_search_wrapper.ps1` כך שכל לוגיקת סינון תהיה קוד אמיתי (לא טקסט מרוסק).
- להוסיף allowlist מיקומים (למשל מרכז בלבד לפי דרישה).
- לשפר regex לניסיון: `3+`, `at least 3`, `minimum 3`, `3 years experience` וכו'.

### בדיקות
- בדיקות מבוססות fixtures:
  - משרה עם `5+ years` נפסלת.
  - משרה מחוץ לאזור מותר נפסלת.
  - משרה מתאימה נשמרת.
- בדיקת תוצאה: `jobs_found.json` תואם expected JSON.

### Exit Criteria
- Precision גבוה: רוב המשרות הלא רלוונטיות נחסמות לפני notification.

---

## שלב 2 — State Machine לזרימת משרה

### מטרות
- מעקב אמין לכל משרה והפסקת "קפיצות" בין שלבים.

### משימות
- להגדיר סטטוסים אחידים:
  - `Found`, `Sent`, `CV_Generating`, `CV_Ready_For_Review`, `CV_Revision_Requested`,
    `Approved_For_Apply`, `Applied`, `Apply_Failed`, `Rejected_By_User`.
- להוסיף שדות בטראקר (CSV או SQLite):
  - `job_id`, `source`, `job_url`, `status`, `status_reason`, `created_at`, `updated_at`,
    `latest_cv_path`, `submitted_cv_path`, `apply_attempts`, `last_error`.

### בדיקות
- בדיקות מעבר סטטוס (valid transitions only).
- אסרט: אין מעבר ל-`Applied` ללא `Approved_For_Apply`.

### Exit Criteria
- לכל משרה יש סטטוס חד-משמעי בכל רגע.

### הרחבה 2.1 — ממשק Telegram יציב ודטרמיניסטי

#### מטרות
- להבטיח סדר שליחה עקבי, תבנית הודעה קבועה, ויכולת שחזור מלאה של dispatch.

#### משימות
- לממש מיון דטרמיניסטי לפני שליחה: `date_posted DESC`, ואז `job_id`, `company`, `title`.
- לרכז בניית הודעה בפונקציה אחת קבועה.
- לשלוח דרך פונקציית dispatch עם Retry קבוע (`maxRetries=3`, `delay=2s`).
- לשמור לוג dispatch לקובץ `memory/telegram_dispatch.log` עבור audit.
- לשמור מיפוי `telegram_message_id -> job_id` בקובץ `memory/telegram_message_map.csv`.
- להוסיף מאזין `getUpdates` לריאקציות 👍 שמפעיל אוטומטית יצירת CV ושולח PDF חזרה למשתמש.
- להוסיף בדיקת זמינות Runtime/Agent לפני התחלת יצירת CV, עם הודעת שגיאה ברורה למשתמש במקרה שהריצה אינה זמינה.
- להוסיף Preflight קשיח לפני יצירת CV:
  - קיום/קריאות של `profile.md`.
  - זמינות `node` ו-`dist/cli.js`.
  - קיום משתני סביבה נדרשים (`GEMINI_API_KEY`, `TELEGRAM_BOT_TOKEN`).
- להחליף את `current_job_desc.txt` הגלובלי בנתיב זמני פר-משרה (למשל `temp/<job_id>/job_desc.txt`) למניעת התנגשות בריצות מקבילות.
- לחבר את בחירת המודל מ-`/models` ו-`/model` ל-Generation runtime בפועל (לא רק מצב UI).

#### בדיקות
- בדיקה חוזרת עם אותו קלט: סדר ההודעות נשאר זהה בכל ריצה.
- בדיקת הודעות ניסיון לטלגרם באמצעות `scripts/telegram_send_test_messages.ps1`.
- אימות משתמש בפועל בטלגרם: הודעות נפרדות, תבנית אחידה, וסדר קבוע.
- בדיקת prerequisite: אם Runtime/Agent ליצירת CV לא פעיל — מתקבלת הודעת כשל ברורה ואין מעבר שקט.
- בדיקת preflight של `profile.md`: אם הקובץ חסר/לא קריא — אין התחלת generation, סטטוס ולוג מתעדכנים עם הסיבה.
- בדיקת race-condition: שתי ריאקציות מהירות על משרות שונות אינן דורסות קלט job description.
- בדיקת model wiring: בחירת מודל בצ'אט משנה בפועל את המודל שבו generation רץ.
- בדיקת ריאקציה: לאחר הודעת משרה, תגובת 👍 צריכה להעביר סטטוס ל-`CV_Generating` ואז `CV_Ready_For_Review` עם שליחת PDF.

#### בדיקת End-to-End מומלצת (ידנית)
1. להריץ שליחת הודעות ניסיון: `powershell -NoProfile -File scripts/telegram_send_test_messages.ps1 -Count 3`
2. להריץ מאזין תגובות: `powershell -NoProfile -File scripts/telegram_reaction_listener.ps1`
3. לוודא ש-Runtime/Agent ליצירת CV פעיל בסביבה המקומית.
4. להגיב 👍 להודעת משרה בטלגרם.
5. לוודא:
  - התקבל PDF review בטלגרם.
  - `job_tracker.csv` עודכן ל-`CV_Ready_For_Review`.
  - נרשם dispatch log בקבצי `memory/telegram_dispatch.log` ו-`memory/telegram_message_map.csv`.

#### Exit Criteria
- שליחת ההודעות למשתמש מתבצעת בסדר עקבי ותבנית אחידה, עם לוג dispatch מלא.
- זרימת יצירת CV תלויה ב-Runtime/Agent פעיל ומחזירה הודעת guidance ברורה אם prerequisite חסר.
- `profile.md` מוגדר ומטופל כמקור CV גנרי ב-Markdown לאורך כל הזרימה.

---

## שלב 3 — אישור ידני ועריכה של CV

### מטרות
- לאפשר review + revisions לפני הגשה.

### משימות
- להבהיר שהבסיס ליצירה הוא `profile.md` (Markdown) + תיאור משרה, ולא קלט PDF קיים.
- בעת Generate: לשמור כ-`Generated_CVs/<job_id>/draft_vN.pdf`.
- לשלוח למשתמש הודעת review עם אפשרויות:
  - אישור
  - בקשת עריכה
  - דחייה
- בקשת עריכה מייצרת גרסה חדשה (`v2`, `v3`...).

### בדיקות
- יצירת 2-3 גרסאות לאותה משרה ללא דריסה.
- דחייה מעדכנת `Rejected_By_User`.
- אישור מעדכן `Approved_For_Apply`.

### Exit Criteria
- לא מתבצעת הגשה לפני אישור ידני מפורש.

---

## שלב 4 — ארכיון קבצים שהוגשו + תיעוד מלא

### מטרות
- שמירת הוכחה למה הוגש בפועל ומתי.

### משימות
- לפני Apply: להעתיק את קובץ ה-CV המאושר ל-
  `Submitted_CVs/<job_id>/submitted_<timestamp>.pdf`.
- לשמור hash (למשל SHA-256) ונתיב קובץ בטראקר.
- לשמור לוג apply תמציתי לפי `job_id`.

### בדיקות
- לכל `Applied` יש `submitted_cv_path` קיים.
- hash אינו ריק ותואם לקובץ.

### Exit Criteria
- Audit trail מלא לכל הגשה.

---

## שלב 5 — Apply יציב (Semi-Automatic by default)

### מטרות
- לצמצם חסימות אנטי-בוט באתרים רגישים.

### משימות
- להגדיר מצב ברירת מחדל `manual_assist` עבור LinkedIn:
  - הסוכן פותח/מנווט, המשתמש מאשר/לוחץ submit.
- לשמור `auto_apply` רק לאתרים שבהם היציבות גבוהה.
- שגיאות apply נכתבות ל-`Apply_Failed` + reason.

### בדיקות
- LinkedIn: flow מצליח ללא חסימה ברוב ניסויי smoke.
- במקרה חסימה: המערכת לא נתקעת, מעדכנת סטטוס נכון.

### Exit Criteria
- אחוז הצלחה יציב בהגשה בפועל + התאוששות תקינה משגיאות.

---

## שלב 6 — אופטימיזציית עומס Gemini

### מטרות
- להוריד זמן/עלות ולהפחית 429/503.

### משימות
- Queue חד-ערוצי ל-CV generation.
- הורדת `thinkingBudget` כברירת מחדל (למשל 1024/2048).
- `refine` רק אם בדיקות איכות נכשלות (conditional refine).
- Cache לתוצאות ביניים לפי `job_id + profile_hash`.

### בדיקות
- השוואת זמני ריצה לפני/אחרי.
- ירידה במספר retries ושגיאות rate-limit.
- איכות PDF נשמרת במדגם ידני.

### Exit Criteria
- זמן תגובה יציב ועלות נמוכה יותר בלי ירידת איכות משמעותית.

---

## 4) ארכיטקטורה מומלצת לפרויקט

## 4.1 רכיבים לוגיים

1. **Job Ingestion Service** (Python)
   - אחריות: שליפת משרות (JobSpy), נרמול ראשוני.
   - קלט: `search_config.json`
   - פלט: `jobs_raw.json`

2. **Filtering Engine** (Python/PowerShell)
   - אחריות: סינון ניסיון/מיקום/טייטל/טריות.
   - פלט: `jobs_filtered.json`

3. **State Store** (מומלץ SQLite; אפשר זמנית CSV)
   - אחריות: מקור אמת למצב משרה, גרסאות CV, תוצאת Apply.

4. **Notification & Approval Controller** (Telegram)
   - אחריות: שליחת משרה, קבלת אישור/דחייה/עריכה, טריגר לשלבים הבאים.
   - מוד פעולה מומלץ: polling מקומי בשלב ראשון, webhook בפרודקשן.

5. **CV Generation Service** (Node, Gemini)
   - אחריות: יצירת draft, refine מותנה, export PDF, ניהול גרסאות.

6. **Apply Assistant** (Browser/OpenClaw/Puppeteer)
   - אחריות: ניווט הגשה, מצב חצי-ידני לאתרים רגישים.

7. **Audit & Storage Layer**
   - תיקיות קבצים:
     - `Generated_CVs/<job_id>/draft_vN.pdf`
     - `Submitted_CVs/<job_id>/submitted_<timestamp>.pdf`
   - לוגים לפי `job_id`.

---

## 4.2 זרימת אירועים מומלצת

`Search -> Filter -> Notify -> (User decision)`

- אם אישור יצירת CV:
  `Generate Draft -> Review -> (Edit loop)* -> Approve`

- אם אישור הגשה:
  `Archive Submitted PDF -> Apply Assist -> Applied/Failed`

- בכל נקודה:
  `State Store update + structured log`

---

## 4.3 מבנה תיקיות מומלץ

- `src/` — קוד אפליקטיבי
- `scripts/` — סקריפטים תפעוליים (search/filter/process)
- `data/` — state & runtime json/csv/sqlite
- `Generated_CVs/` — טיוטות review
- `Submitted_CVs/` — קבצים שהוגשו בפועל
- `tests/fixtures/` — דגימות משרות לבדיקות סינון
- `docs/` — תיעוד מערכת והפעלה

---

## 4.4 המלצה טכנולוגית ל-State

- **טווח קצר:** המשך עם `job_tracker.csv` + סכמת שדות מורחבת.
- **טווח בינוני:** מעבר ל-`SQLite` (atomic updates, שאילתות, היסטוריה יציבה).

---

## 4.5 ניטור ותפעול

- מדדים בסיסיים:
  - `jobs_fetched`, `jobs_filtered_in`, `jobs_filtered_out`
  - `cv_generated_count`, `cv_revision_count`
  - `apply_success_rate`, `apply_failure_reason_topN`
  - `gemini_retry_count`, `avg_generation_time`
- Health checks:
  - Telegram token תקין
  - Gemini API זמין
  - דפדפן/פרופיל זמין

---

## 5) Definition of Done (DoD)

פיצ'ר נחשב "גמור" רק אם:
1. יש בדיקות חיוביות ושליליות.
2. סטטוס משרה מתעדכן נכון בכל מסלול.
3. אין Apply ללא אישור ידני.
4. קובץ שהוגש נשמר בארכיון עם timestamp.
5. לוגים מאפשרים שחזור מלא של האירוע.

---

## 6) תוכנית ביצוע מומלצת (סדר עבודה)

1. שלב 1 (סינון) — קריטי ומיידי.
2. שלב 2 (State machine) — לייצב את הזרימה.
3. שלב 3 (Review + Revision) — לאפשר אישור/עריכה אמיתיים.
4. שלב 4 (Archive + audit) — תיעוד הגשות.
5. שלב 5 (Apply semi-automatic) — לשפר הצלחה בלינקדאין.
6. שלב 6 (Gemini optimization) — הורדת עומס/עלות.

---

## 7) הערות יישום ספציפיות לפרויקט הנוכחי

- את `src/types.ts` הנוכחי כדאי לשמר ולהרחיב (`jobUrl` כבר תוספת טובה).
- את `withRetry` ב-`src/gemini.ts` כדאי לשמר, אבל להוסיף policy של budget דינמי.
- את `apply` ב-`src/cli.ts` מומלץ לפצל לשני מצבים: `manual_assist` ו-`auto_apply`.
- יש לתקן תחילה את `job_search_wrapper.ps1` לפני כל אופטימיזציה אחרת.
- ב-Guardrails של CV יש להבדיל בין **עובדות ליבה קשיחות** לבין **טקסט תיאורי**:
  - קשיח: שם/טלפון/אימייל, קישורים נעולים, כותרות/עובדות ליבה ב-Education (תואר/מוסד/שנים).
  - גמיש: בולטים תיאוריים של פרויקטים/ניסיון (ניתן לקצר/לנסח מחדש).
- ולידציה קשיחה על כל שורות `Education` מייצרת false failures (במיוחד במסמך עמוד אחד), ולכן יש לאכוף רק core facts.
- מנגנון placeholders לקישורים הוא חלק חובה כדי למנוע החלפה ללינקים כלליים במקום לינקי פרויקט ספציפיים.
- סטטוס CandleKeep (2026-03-06): `ck` פעיל וזמין (`C:\Users\rened\.cargo\bin\ck.exe`), אך ב-VS integrated terminal (במיוחד `bash`) נדרש לוודא שהנתיב `C:\Users\rened\.cargo\bin` נמצא ב-PATH.
- בקרת אורך פלט (החלטה ארכיטקטונית): אומצה אסטרטגיית multi-layer הכוללת budget לפי סקשנים בפרומפט + two-pass compaction + בדיקת A4 runtime + retries מוגבלים. ראו: `docs/CV_OUTPUT_LENGTH_CONTROL_DECISION.md`.

### שלבי פיתוח לבקרת אורך (בוצע/מבוצע)

1. להגדיר תקציבי תוכן לכל סקשן (Summary/Skills/Experience/Projects/Education).
2. להוסיף בדיקת one-page על HTML מרונדר לפני export ל-PDF.
3. אם חורג: להפעיל pass דחיסה ייעודי תוך שימור עובדות קשיחות וקישורים נעולים.
4. לבצע עד 2 ניסיונות דחיסה לפני fail קשיח במצב strict.
5. לאמת ב-smoke tests ש:
  - אין חריגה לעמוד שני,
  - אין שינוי בעובדות ליבה,
  - אין החלפת לינקי פרויקטים ללינקים כלליים.

---

אם רוצים, אפשר לפרק את המסמך הזה למסמכי משנה:
- `docs/ARCHITECTURE.md`
- `docs/ROADMAP.md`
- `docs/TEST_PLAN.md`
- `docs/OPERATIONS.md`
