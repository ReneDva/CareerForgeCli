#!/usr/bin/env python3
import argparse
import sys
from jobspy import scrape_jobs
import pandas as pd

def main():
    parser = argparse.ArgumentParser(description="JobSpy CLI Wrapper for CareerForge")
    parser.add_argument("--query", "-q", type=str, required=True, help="Job title or search term")
    parser.add_argument("--location", "-l", type=str, default="Remote", help="Location")
    parser.add_argument("--results", "-r", type=int, default=10, help="Number of results to fetch per site")
    parser.add_argument("--hours-old", "-H", type=int, default=24, help="Fetch jobs posted within X hours")
    parser.add_argument("--out", "-o", type=str, help="Output JSON file. If not provided, prints to stdout.")
    
    args = parser.parse_args()
    
    try:
        jobs: pd.DataFrame = scrape_jobs(
            site_name=["linkedin", "indeed", "glassdoor", "zip_recruiter"],
            search_term=args.query,
            location=args.location,
            results_wanted=args.results,
            hours_old=args.hours_old,
            country_alice="USA"
        )
        
        # Convert date column to string to make it JSON serializable
        if 'date' in jobs.columns:
            jobs['date'] = jobs['date'].astype(str)
            
        json_data = jobs.to_json(orient="records")
        
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(json_data)
            print(f"✅ Saved {len(jobs)} jobs to {args.out}")
        else:
            print(json_data)
            
    except Exception as e:
        print(f"Error scraping jobs: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
