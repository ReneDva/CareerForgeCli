## 🛠️ סיכום הבעיות והפתרונות (מעודכן 2026-03-03)

| הבעיה | מה גרם לה? | הפתרון שביצענו |
| --- | --- | --- |
| **Blocked skill env overrides** | ה-Gateway חסם הזרקת מפתחות API מסיבות אבטחה. | הגדרת המפתח בתוך **Auth Profile** מרכזי. |
| **503 Service Overloaded** | עומס נקודתי על מודל ה-Pro של גוגל. | שימוש ב-**Retry Logic** ומעבר זמני ל-Flash. |
| **Model Not Allowed** | המודל לא היה ברשימת המורשים ב-Config. | הוספת המודל ל-**Allowlist** דרך תפריט `models`. |
| **CLI Argument Errors** | גרסת 2026.3 דורשת תחביר קשוח (Strict Schema). | עדכון ה-JSON למבנה **Root-level Tools** ושימוש בדגלים מפורשים. |
| **LinkedIn Tab Disconnect** | זיהוי אוטומציה (CDP) ע"י לינקדאין בניתוב ישיר. | מעבר ל-**Extension Relay** (פרופיל `chrome`) והצמדה ידנית. |
| **LinkedIn Interaction Block** | זיהוי בוט לפי מהירות לחיצה מכנית. | שימוש ב-**Human-like Interaction** (Hover + Jitter Click). |

---

## 💻 הפקודות שעבדו (והמשמעות שלהן)

### 1. ניהול הרשאות וזהות (Auth & Browser)

* `openclaw browser --browser-profile chrome tabs`
* **מה זה עשה:** אימת שה-Gateway "רואה" את הטאבים של הכרום האישי שלך דרך התוסף.


* `openclaw models auth add --agent careerforgecli`
* **מה זה עשה:** שמירת ה-API Key במחסן המאובטח של OpenClaw.



### 2. ניהול דפדפן וסנדבוקס

* `sandbox: { "mode": "off" }` (בתוך `openclaw.json`)
* **מה זה עשה:** ביטל בידוד מיותר שגרם לניתוק ה-Debugger מאתרים חיצוניים.


* `openclaw browser extension install`
* **מה זה עשה:** התקנת ה"גשר" לכרום שמאפשר שליטה בטאבים קיימים ללא פתיחת חלון חדש.



---

## 🚀 אסטרטגיית עקיפת חסימות (LinkedIn Stealth)

כדי לעבוד על אתרים רגישים (LinkedIn/X), אנחנו משתמשים בשיטת ה-**Pincer Maneuver**:

1. **Manual Launch:** המשתמש פותח את הטאב ומבצע Login.
2. **Extension Attach:** לחיצה על התוסף (מצב ON) לחיבור ה-Relay.
3. **Human Simulation:** הנחיה לסוכן לבצע פעולות בסדר הבא:
* `Scroll` (הבאה ל-Viewport).
* `Hover` (דימוי תנועת עכבר).
* `Human-like click` (לחיצה עם השהיה ורעש סטטיסטי).



---

## 📝 תיעוד פנימי (English Documentation)

הוספתי את הלוגיקה החדשה לתיעוד הפרויקט:

```typescript
/**
 * 2026 Deployment & Stealth Summary:
 * 1. USE AUTH PROFILES: Avoid env vars for API keys in multi-agent setups.
 * 2. ROOT-LEVEL TOOLS: Ensure 'tools' block is at the JSON root, not nested.
 * 3. STEALTH BYPASS: For sensitive sites (LinkedIn), use 'chrome' profile via 
 * Extension Relay instead of managed 'openclaw' profile to leverage existing session.
 * 4. HUMAN INTERACTION: Always sequence actions: Scroll -> Hover -> Human-Click 
 * to bypass behavioral heuristic analysis.
 */
export const DEPLOYMENT_INFO = "CareerForge stable with LinkedIn Stealth enabled";

```

---

**הסטטוס הנוכחי:** הסוכן מסוגל לקרוא פוסטים מלינקדאין ולבצע אינטראקציות (כמו לייק) מבלי שהטאב יתנתק.
