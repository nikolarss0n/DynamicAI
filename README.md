# DynamicAI

A macOS Dynamic Island-style chat app with smart photo/video search powered by local indexes and Groq LLM.

## Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| **App** | Swift/SwiftUI | macOS native app |
| **LLM** | Groq (Llama 3.3 70B) | Query parsing, video matching |
| **Vision AI** | Groq (Llama 4 Scout) | Video frame analysis |
| **Photo Access** | Apple Photos Framework | Access user's photo library |
| **Image Classification** | Apple Vision Framework | Local label extraction |

### Why Groq?

- **Fast**: 100-200ms response times (vs 1-2s for OpenAI)
- **Cheap**: ~$0.05/M input tokens (vs $2.50 for GPT-4)
- **Good enough**: Llama 3.3 70B handles our use cases well

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      User Query                              │
│                 "beach photos from Greece"                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    SmartQueryParser                          │
│              (Groq LLM - 1 API call)                        │
│                                                              │
│  Output: { location: "Greece", labels: ["beach"] }          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Local Indexes (No API)                    │
├─────────────────┬─────────────────┬─────────────────────────┤
│  GeoHashIndex   │   LabelIndex    │   PHAsset (Native)      │
│  Location O(1)  │  Labels O(1)    │   Date/People filter    │
└─────────────────┴─────────────────┴─────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Matching Photos                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Photo Indexing

We use **lightweight local indexes** - no embeddings or vector databases required.

### Indexes

| Index | What it does | Lookup Time |
|-------|--------------|-------------|
| **GeoHashIndex** | Encodes lat/lng into geohash strings | O(1) |
| **LabelIndex** | Apple Vision labels (beach, dog, person) | O(1) |
| **PHAsset** | Native date/people filtering | Native |

### Indexing Flow

```
Photo
  │
  ├──► Apple Vision ──► labels: ["beach", "outdoor", "person"]
  │
  ├──► CoreLocation ──► geohash: "u33dc0"
  │
  └──► Store in memory + disk cache
```

**API calls for photo indexing: 0** (all local processing)

---

## Video Indexing

Videos require AI to understand the activity happening. We use a **contact sheet** approach.

### Indexing Flow

```
Video (e.g., 30 seconds)
  │
  ├──► Extract 3 frames (at 25%, 50%, 75% of duration)
  │
  ├──► Stitch into contact sheet (single image, 3 panels)
  │
  ├──► Send to Groq Vision (Llama 4 Scout)
  │         │
  │         └──► "Person jumping rope in a gym setting"
  │
  ├──► Apple Vision ──► labels: ["person", "indoor", "sports"]
  │
  └──► Store VideoActivityInfo
```

### Stored Data per Video

```swift
struct VideoActivityInfo {
    activitySummary: String  // "Person jumping rope in gym"
    keywords: [String]       // ["jumping", "rope", "gym"]
    visualLabels: [String]   // ["person", "indoor", "sports"]
    duration: Double
}
```

**API calls for video indexing: 1 per video** (Groq Vision)

---

## Search Flow

### Photo Search

```
User: "beach photos from Greece"
        │
        ▼
┌───────────────────────────────────────┐
│ 1. Parse with Groq LLM                │  ← 1 API call
│    → {location: "Greece",             │
│       labels: ["beach"]}              │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 2. GeoHashIndex.search("Greece")      │  ← Local
│    → [photo IDs near Greece]          │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 3. LabelIndex.search(["beach"])       │  ← Local
│    → [photo IDs with beach label]     │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 4. Intersect results                  │
│    → Final matching photos            │
└───────────────────────────────────────┘
```

### Video Search (LLM-First Approach)

For videos, we skip complex query parsing and let the LLM do semantic matching directly:

```
User: "show me videos where I jump rope"
        │
        ▼
┌───────────────────────────────────────┐
│ 1. Detect video search                │  ← 1 API call (parse)
│    (keyword "video" in query)         │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 2. Send to LLM:                       │  ← 1 API call (match)
│    - Raw user query                   │
│    - All video descriptions           │
│    - "Pick matching videos"           │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 3. LLM returns matching indices       │
│    → [23, 37, 57, 79, 147]           │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 4. Map to asset IDs                   │
│    → Return matching videos           │
└───────────────────────────────────────┘
```

This approach lets the LLM understand semantic differences like:
- "jumping rope" ≠ "baby in jumper seat"
- "playing golf" ≠ "other outdoor activities"

---

## API Calls Summary

| Operation | Groq API Calls | Notes |
|-----------|----------------|-------|
| Index 1 photo | 0 | Apple Vision only (local) |
| Index 1 video | 1 | Groq Vision for activity description |
| Photo search | 1-2 | Parse query + optional geocoding |
| Video search | 2 | Parse query + LLM semantic matching |

---

## Key Design Decisions

### 1. No Embeddings/Vectors
Local indexes (geohash, labels) are fast enough and much cheaper than vector databases.

### 2. LLM-First for Videos
Video descriptions are semantically rich. Instead of keyword matching, we send the raw user query + all descriptions to the LLM and let it pick matches.

### 3. Contact Sheets for Video Analysis
Stitching 3 frames into 1 image means:
- 1 API call instead of 3
- LLM sees temporal context (beginning, middle, end)
- Better activity understanding

### 4. Groq over OpenAI
- 10x faster response times
- 50x cheaper for our use case
- Llama models are good enough for query parsing and matching

---

## Project Structure

```
DynamicAI/
├── Services/
│   ├── GroqService.swift        # Groq API client (chat + vision)
│   ├── SmartPhotoSearch.swift   # Search orchestrator
│   ├── SmartQueryParser.swift   # LLM query parsing
│   ├── GeoHashIndex.swift       # Location-based indexing
│   ├── LabelIndex.swift         # Vision label indexing
│   ├── VideoIndex.swift         # Video activity indexing
│   ├── PhotosProvider.swift     # Apple Photos access
│   └── AIService.swift          # Main AI service
├── Views/
│   └── ...                      # SwiftUI views
└── DynamicAIApp.swift           # App entry point
```

---

## Setup

1. Clone the repo
2. Open `DynamicAI.xcodeproj` in Xcode
3. Add your Groq API key in Settings
4. Build and run (⌘R)
5. Press ⌘⌥Space to toggle the assistant

---

## Requirements

- macOS 14.0+
- Xcode 15+
- Groq API key (get one at https://console.groq.com)
