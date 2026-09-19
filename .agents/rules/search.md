# Web Search & Page Fetching Guidelines

Use **TinyFish** via Monid as the primary tool for all live web searches and web page fetches.

## Why TinyFish
- **Cost**: 100% FREE ($0/call) for both search and fetches.
- **Freshness**: Live web, uncached browser-rendered results.
- **Capabilities**: Web search, news search, research papers, and clean Markdown extractions (up to 10 URLs in parallel).

## Primary Commands

### 1. Web Search
Run a live web search:
```bash
monid run -p tinyfish -e /search --query '{"query":"<search query>"}' -w
```
Options:
- `"purpose"`: Optional context for ranking (e.g. `"researching API pricing"`).
- `"domain_type"`: `"web"` (default), `"news"`, or `"research_paper"`.
- `"recency_minutes"`: Freshness window (e.g. `60` for past hour).
- `"include_domains"` / `"exclude_domains"`: Filter specific domains.

### 2. Clean Page Fetch (Markdown Extraction)
Fetch and extract clean Markdown from 1-10 URLs:
```bash
monid run -p tinyfish -e /fetch -i '{"urls":["https://example.com"]}' -w
```
Options:
- `"format"`: `"markdown"` (default), `"html"`, or `"json"`.
- `"include_selectors"` / `"exclude_selectors"`: Target or prune specific DOM elements.
