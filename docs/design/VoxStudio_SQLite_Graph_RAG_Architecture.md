# Vox Studio：基于 SQLite 的 Graph-Augmented RAG 架构设计

> 适用场景：Vox Studio 原生 macOS App（Swift / Apple Silicon）  
> 目标：在现有 Hybrid Search + WeMM Embedding + Index 能力基础上，引入轻量图数据存储，在 **Recall 阶段加入 Graph Search**，提升实体关系、多跳关联、跨文档问答的召回质量。  
> 数据库：SQLite（建议 Swift 侧使用 GRDB 封装）  
> Reranker：Qwen3-Reranker-0.6B，MLX 4-bit  
> 原则：**Graph 是 Recall 增强，不替代 Hybrid Search；最终相关性由 Reranker 统一裁决。**

---

## 1. 目标与设计原则

Vox Studio 已有：

- 文档 / 音视频 / ASR transcript 索引
- Hybrid Search
  - Dense / WeMM Embedding
  - BM25 / Keyword
  - RRF / Fusion
- 本地文件与媒体 Source metadata
- Apple Silicon 本地运行环境

本方案新增：

1. Entity / Relation 抽取
2. SQLite Graph Store
3. Entity → 1~3 hop 图搜索
4. Graph Node → Chunk 反向关联
5. Hybrid Recall + Graph Recall 融合
6. Qwen3 Reranker 精排
7. Parent / Neighbor Context Merge
8. Grounded QA

核心原则：

```text
Hybrid Search
= lexical + semantic recall

Graph Search
= relational recall

Reranker
= final relevance judge
```

Graph 不直接回答问题，也不直接替代 Vector/BM25。

---

# 2. 总体架构

```text
                     Query
                       │
                QUERY_UNDERSTAND
                       │
                Entity Extraction
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
 Hybrid Chunk Search          SQLite SearchNode
 Vector + BM25                Entity + 1~3-hop
          │                         │
          ▼                         ▼
      chunks                 graph nodes
                                  │
                                  ▼
                           associated chunks
          │                         │
          └────────────┬────────────┘
                       ▼
                  Merge + Dedup
                       │
                       ▼
                 CHUNK_RERANK
                       │
                       ▼
                  Context Merge
                       │
                       ▼
                      LLM
```

更完整地看：

```text
                                   ┌──────────────────────┐
                                   │      Vox Studio      │
                                   │ Swift / macOS / MLX  │
                                   └──────────┬───────────┘
                                              │
                         ┌────────────────────┴────────────────────┐
                         │                                         │
                         ▼                                         ▼
                  Existing Search                            Graph Store
             WeMM + BM25 + RRF                         SQLite / GRDB
                         │                                         │
                         └────────────────────┬────────────────────┘
                                              ▼
                                      Recall Candidate Pool
                                              │
                                              ▼
                               Qwen3-Reranker-0.6B MLX 4-bit
                                              │
                                              ▼
                                     Context Reconstruction
                                              │
                                              ▼
                                      Local / Cloud LLM
```

---

# 3. 为什么选择 SQLite 而不是 Neo4j

Vox Studio 是原生 Mac App，而不是 Server 产品。

SQLite 更适合：

- 无需用户单独安装
- 无 JVM
- 无后台 DB server
- 无 TCP/Bolt
- 可随 App 沙盒数据一起存储
- 原生 ARM64
- 事务与 crash recovery 成熟
- 易备份 / 删除 / 重建
- 与现有 Swift 数据层集成简单
- 1~3 hop GraphRAG 足够

当前目标不是：

- PageRank
- 社区发现
- 百亿边图分析
- 复杂 Graph Data Science
- 多用户分布式图数据库

而是：

```text
Entity
  ↓
Relation
  ↓
Entity
  ↓
Chunk IDs
```

对这种本地图召回，SQLite 足够。

---

# 4. 数据模型总览

建议 Graph DB 只保存：

```text
Entity
Relation
Entity Alias
Entity ↔ Chunk Link
Graph Source Provenance
```

完整正文仍由 Vox Studio 现有 Chunk Store 管理。

不要在 Graph DB 中复制完整文档。

```text
                           Source / Document
                                  │
                                  ▼
                                Chunk
                                  │
                    ┌─────────────┴──────────────┐
                    │                            │
                    ▼                            ▼
              Search Index                 Graph Extraction
          BM25 + Embedding                      │
                                                ▼
                                              Entity
                                                │
                                           Relationship
                                                │
                                                ▼
                                              Entity
                                                │
                                                ▼
                                           Chunk Links
```

---

# 5. SQLite Schema

## 5.1 entities

```sql
CREATE TABLE graph_entity (
    id                  TEXT PRIMARY KEY,
    canonical_name      TEXT NOT NULL,
    normalized_name     TEXT NOT NULL,
    entity_type         TEXT,
    description         TEXT,

    confidence          REAL DEFAULT 1.0,

    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

CREATE INDEX idx_graph_entity_normalized_name
ON graph_entity(normalized_name);

CREATE INDEX idx_graph_entity_type
ON graph_entity(entity_type);
```

示例：

```text
id               = entity_qwen3_asr
canonical_name   = Qwen3-ASR
normalized_name  = qwen3-asr
entity_type      = MODEL
```

---

## 5.2 entity aliases

解决：

```text
Qwen 3 ASR
Qwen3-ASR
Qwen ASR
Qwen3 ASR 1.7B
```

等不同写法。

```sql
CREATE TABLE graph_entity_alias (
    entity_id           TEXT NOT NULL,
    alias               TEXT NOT NULL,
    normalized_alias    TEXT NOT NULL,

    PRIMARY KEY(entity_id, normalized_alias),

    FOREIGN KEY(entity_id)
        REFERENCES graph_entity(id)
        ON DELETE CASCADE
);

CREATE INDEX idx_graph_alias_normalized
ON graph_entity_alias(normalized_alias);
```

---

## 5.3 relations

```sql
CREATE TABLE graph_relation (
    id                  TEXT PRIMARY KEY,

    source_entity_id    TEXT NOT NULL,
    target_entity_id    TEXT NOT NULL,

    relation_type       TEXT NOT NULL,

    weight              REAL DEFAULT 1.0,
    confidence          REAL DEFAULT 1.0,

    source_id           TEXT,
    source_chunk_id     TEXT,

    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY(source_entity_id)
        REFERENCES graph_entity(id)
        ON DELETE CASCADE,

    FOREIGN KEY(target_entity_id)
        REFERENCES graph_entity(id)
        ON DELETE CASCADE
);

CREATE INDEX idx_relation_source
ON graph_relation(source_entity_id);

CREATE INDEX idx_relation_target
ON graph_relation(target_entity_id);

CREATE INDEX idx_relation_type
ON graph_relation(relation_type);

CREATE INDEX idx_relation_source_target
ON graph_relation(source_entity_id, target_entity_id);
```

---

## 5.4 entity ↔ chunk

```sql
CREATE TABLE graph_entity_chunk (
    entity_id           TEXT NOT NULL,
    chunk_id            TEXT NOT NULL,
    source_id           TEXT NOT NULL,

    mention_count       INTEGER DEFAULT 1,
    relevance           REAL DEFAULT 1.0,

    start_offset        INTEGER,
    end_offset          INTEGER,

    PRIMARY KEY(entity_id, chunk_id),

    FOREIGN KEY(entity_id)
        REFERENCES graph_entity(id)
        ON DELETE CASCADE
);

CREATE INDEX idx_entity_chunk_entity
ON graph_entity_chunk(entity_id);

CREATE INDEX idx_entity_chunk_chunk
ON graph_entity_chunk(chunk_id);

CREATE INDEX idx_entity_chunk_source
ON graph_entity_chunk(source_id);
```

---

## 5.5 source graph state

用于增量 index 和重新构建。

```sql
CREATE TABLE graph_source_state (
    source_id               TEXT PRIMARY KEY,

    content_hash            TEXT NOT NULL,
    graph_schema_version    INTEGER NOT NULL,
    extractor_version       TEXT NOT NULL,

    indexed_at              INTEGER NOT NULL
);
```

当：

```text
content_hash unchanged
```

则不重新构建 Graph。

---

# 6. Entity Type 建议

第一版不要允许无限自由类型。

推荐固定一套轻量 taxonomy：

```text
PERSON
ORGANIZATION
PROJECT
PRODUCT
MODEL
TECHNOLOGY
FEATURE
COMPONENT
FILE
DOCUMENT
MEETING
TOPIC
LOCATION
DATE
VERSION
ERROR_CODE
OTHER
```

Vox Studio 技术知识库尤其重要：

```text
MODEL
COMPONENT
TECHNOLOGY
VERSION
ERROR_CODE
PROJECT
```

---

# 7. Relation Type 设计

同样建议先做有限集合。

```text
USES
USED_BY

PART_OF
HAS_PART

DEPENDS_ON
REQUIRED_BY

CREATED_BY
MAINTAINED_BY

WORKS_ON
RESPONSIBLE_FOR

DISCUSSED_IN
MENTIONED_IN

IMPLEMENTS
SUPPORTED_BY

RELATED_TO

REPLACES
SUPERSEDES

VERSION_OF

INTEGRATES_WITH
```

第一版最好允许：

```text
relation_type = RELATED_TO
```

作为 fallback。

避免 LLM 因 taxonomy 不够完整生成大量随机 relation。

---

# 8. Data Ingestion 总流程

```text
                       New Source
                           │
                           ▼
                    Parse / ASR / OCR
                           │
                           ▼
                         Chunk
                           │
                ┌──────────┴──────────┐
                │                     │
                ▼                     ▼
        Existing Search Index    Graph Extraction
      BM25 + WeMM Embedding           │
                                      ▼
                              Entity Extraction
                                      │
                                      ▼
                             Relation Extraction
                                      │
                                      ▼
                          Entity Canonicalization
                                      │
                                      ▼
                              Alias Resolution
                                      │
                                      ▼
                           Upsert Entity / Relation
                                      │
                                      ▼
                              Entity-Chunk Link
                                      │
                                      ▼
                                  SQLite
```

---

# 9. Ingestion Step 1：Source Parse

不同数据源统一成：

```swift
struct SourceDocument {
    let sourceID: String
    let sourceType: SourceType

    let title: String
    let text: String

    let metadata: SourceMetadata
}
```

例如：

```text
PDF
Word
Markdown
Web
Audio transcript
Meeting transcript
Video transcript
Project notes
```

---

# 10. Ingestion Step 2：Chunk

沿用 Vox Studio 已有 Chunk pipeline。

建议 Chunk metadata 至少有：

```swift
struct Chunk {
    let id: String
    let sourceID: String

    let content: String

    let title: String?
    let sectionBreadcrumb: String?

    let chunkIndex: Int

    let parentChunkID: String?

    let prevChunkID: String?
    let nextChunkID: String?

    let startTime: Double?
    let endTime: Double?

    let page: Int?
}
```

Graph 使用的最重要字段：

```text
chunk_id
source_id
content
```

---

# 11. Ingestion Step 3：Entity Extraction

推荐使用一个轻量 LLM。

输入：

```text
Document title
Section breadcrumb
Chunk content
```

Prompt：

```text
Extract named entities that are useful for knowledge retrieval.

Return only entities that may help connect information across chunks
or documents.

Entity types:
PERSON, ORGANIZATION, PROJECT, PRODUCT, MODEL, TECHNOLOGY,
FEATURE, COMPONENT, FILE, DOCUMENT, MEETING, TOPIC,
LOCATION, DATE, VERSION, ERROR_CODE, OTHER.

Do not extract generic nouns unless they are meaningful concepts.

Return JSON only.
```

输出：

```json
{
  "entities": [
    {
      "name": "Qwen3-ASR",
      "type": "MODEL",
      "confidence": 0.98
    },
    {
      "name": "Vox Studio",
      "type": "PRODUCT",
      "confidence": 0.99
    }
  ]
}
```

---

# 12. Ingestion Step 4：Relation Extraction

可以与 Entity Extraction 同一次 LLM 调用完成。

推荐输出：

```json
{
  "entities": [
    {
      "id": "e1",
      "name": "Qwen3-ASR",
      "type": "MODEL"
    },
    {
      "id": "e2",
      "name": "Vox Studio ASR",
      "type": "COMPONENT"
    }
  ],
  "relations": [
    {
      "source": "e2",
      "relation": "USES",
      "target": "e1",
      "confidence": 0.94
    }
  ]
}
```

关键原则：

> Relation 必须有 provenance。

即：

```text
source_id
chunk_id
```

必须记录。

以后回答：

```text
“为什么系统认为 Vox Studio ASR 使用 Qwen3-ASR？”
```

可以回到证据 chunk。

---

# 13. Ingestion Step 5：Entity Canonicalization

Graph 最大的问题不是 relation，而是实体重复。

例如：

```text
OpenAI
Open AI
OpenAI Inc.
openai
```

必须尽量合并。

推荐分三层：

```text
Level 1
Exact normalized match

Level 2
Alias table

Level 3
Embedding / LLM entity resolution
```

---

## 13.1 Normalization

```text
trim
lowercase
Unicode normalize
collapse whitespace
normalize hyphen
```

例如：

```text
Qwen 3 - ASR
→
qwen3-asr
```

---

## 13.2 Exact / Alias

查询：

```sql
SELECT entity_id
FROM graph_entity_alias
WHERE normalized_alias = ?;
```

---

## 13.3 Semantic Resolution

只有 exact 不命中时才使用。

例如候选：

```text
Qwen 3 ASR
Qwen3-ASR
Alibaba Qwen ASR
```

可以复用 WeMM Embedding 做 Entity Name similarity。

不要新增第二套 embedding model。

---

# 14. Entity Upsert

伪代码：

```swift
func resolveEntity(
    extracted: ExtractedEntity
) async throws -> EntityID {

    let normalized = normalize(extracted.name)

    if let existing =
        try graphStore.findEntityByName(normalized) {
        return existing.id
    }

    if let alias =
        try graphStore.findEntityByAlias(normalized) {
        return alias.entityID
    }

    if let semantic =
        try await entityResolver.findSemanticMatch(extracted) {
        return semantic.id
    }

    return try graphStore.createEntity(extracted)
}
```

---

# 15. Relation Upsert

同一个关系可能在多个 chunk 中重复出现：

```text
A USES B
```

不要简单覆盖。

推荐：

```text
EntityRelation
      │
      ├── relation edge
      │
      └── provenance[]
```

第一版 SQLite 可以：

```text
graph_relation
```

一条 edge 对应一条 provenance。

Query 阶段再聚合。

或者另外建：

```sql
graph_relation_evidence
```

长期更推荐。

---

# 16. 删除 / 更新 Source

本地知识库一定要处理：

```text
文件删除
文件更新
ASR transcript 重生成
视频项目改变
```

推荐 Source-level replacement：

```text
BEGIN TRANSACTION

DELETE relation evidence
WHERE source_id = ?

DELETE entity_chunk
WHERE source_id = ?

重新 extraction

upsert entity

insert relation/evidence

update graph_source_state

COMMIT
```

不要因为一个文件被删除就直接删除所有 Entity。

Entity 可能仍被其他文档引用。

---

# 17. Orphan Entity 清理

Source 更新后：

```sql
DELETE FROM graph_entity
WHERE id NOT IN (
    SELECT entity_id
    FROM graph_entity_chunk
)
AND id NOT IN (
    SELECT source_entity_id
    FROM graph_relation
    UNION
    SELECT target_entity_id
    FROM graph_relation
);
```

建议：

```text
background maintenance
```

运行，而不是阻塞文档保存。

---

# 18. Query Pipeline 总流程

```text
User Query
    │
    ▼
Normalize
    │
    ▼
Conversation Context
    │
    ▼
Query Rewrite
    │
    ▼
Entity Extraction
    │
    ├────────────────────────────┐
    │                            │
    ▼                            ▼
Hybrid Search              Graph Search
Vector + BM25              Resolve Entity
    │                            │
    │                       1~3 hop walk
    │                            │
    │                       Entity → Chunk
    │                            │
    └───────────────┬────────────┘
                    ▼
               Candidate Fusion
                    │
                    ▼
                   Dedup
                    │
                    ▼
                 Rerank
                    │
                    ▼
              Context Builder
                    │
                    ▼
                    LLM
```

---

# 19. QUERY_UNDERSTAND

输入：

```text
Current query
Conversation history
Current project / file scope
```

输出：

```swift
struct QueryUnderstanding {
    let originalQuery: String

    let retrievalQuery: String

    let entities: [QueryEntity]

    let graphIntent: GraphIntent

    let filters: QueryFilters
}
```

---

# 20. Query Rewrite

例：

```text
History:
User: Vox Studio 的 ASR 用什么模型？
Assistant: ...

Current:
它和 Whisper 相比呢？
```

Rewrite：

```text
Compare the ASR model used by Vox Studio with Whisper.
```

Graph Entity：

```text
Vox Studio ASR
Whisper
```

---

# 21. Query Entity Extraction

Query 侧 Entity Extraction 应比 Ingestion 更轻。

Prompt：

```text
Extract entities from the user query that are useful
for graph retrieval.

Prefer:
- people
- companies
- projects
- products
- models
- technologies
- components
- files
- meetings
- versions
- error codes

Output entity names only.
```

输出：

```json
[
  "Vox Studio ASR",
  "Whisper"
]
```

---

# 22. 什么时候启用 Graph Search

第一版可以非常简单：

```text
entities.count > 0
→ Graph Search
```

但长期建议使用 Graph Intent。

```swift
enum GraphIntent {
    case none
    case entityLookup
    case relationship
    case multiHop
}
```

---

## 22.1 推荐 Routing

### none

```text
“如何导出 mp4？”
```

不一定需要 Graph。

### entityLookup

```text
“Qwen3-ASR 是什么？”
```

1-hop。

### relationship

```text
“Qwen3-ASR 和 Vox Studio 什么关系？”
```

1~2 hop。

### multiHop

```text
“David 负责的模块使用了哪些模型？”
```

2~3 hop。

---

# 23. SearchNode：实体解析

Graph Search 不能直接拿自由文本 query 遍历。

流程：

```text
Query Entity
    ↓
Canonicalization
    ↓
graph_entity
    ↓
Entity ID
```

SQL：

```sql
SELECT id, canonical_name, entity_type
FROM graph_entity
WHERE normalized_name = ?
LIMIT 10;
```

若无：

```sql
SELECT e.id, e.canonical_name, e.entity_type
FROM graph_entity_alias a
JOIN graph_entity e
  ON e.id = a.entity_id
WHERE a.normalized_alias = ?
LIMIT 10;
```

---

# 24. 1-Hop Graph Search

```sql
SELECT
    r.source_entity_id,
    r.relation_type,
    r.target_entity_id,
    r.weight,
    r.confidence
FROM graph_relation r
WHERE r.source_entity_id = ?
   OR r.target_entity_id = ?;
```

---

# 25. 1~3 Hop：Recursive CTE

推荐 SQLite Recursive CTE。

```sql
WITH RECURSIVE graph_walk AS (

    SELECT
        ? AS entity_id,
        0 AS depth,
        1.0 AS path_score,
        CAST(? AS TEXT) AS path

    UNION ALL

    SELECT
        CASE
            WHEN r.source_entity_id = gw.entity_id
            THEN r.target_entity_id
            ELSE r.source_entity_id
        END AS entity_id,

        gw.depth + 1,

        gw.path_score
        * r.weight
        * r.confidence,

        gw.path || '>' ||
        CASE
            WHEN r.source_entity_id = gw.entity_id
            THEN r.target_entity_id
            ELSE r.source_entity_id
        END

    FROM graph_walk gw

    JOIN graph_relation r
      ON r.source_entity_id = gw.entity_id
      OR r.target_entity_id = gw.entity_id

    WHERE gw.depth < :max_depth

)

SELECT
    entity_id,
    MIN(depth) AS min_depth,
    MAX(path_score) AS best_path_score

FROM graph_walk

GROUP BY entity_id

ORDER BY
    min_depth ASC,
    best_path_score DESC;
```

建议：

```text
max_depth = 1~3
```

绝对不要默认无限递归。

---

# 26. 防止 Graph Explosion

必须有限制：

```yaml
graph:
  max_depth: 2
  max_nodes_per_hop: 20
  max_total_nodes: 80
  max_chunks: 30
```

排序：

```text
Relation confidence
×
Edge weight
×
Hop decay
```

推荐：

```text
hop_decay:

0-hop = 1.0
1-hop = 0.85
2-hop = 0.65
3-hop = 0.45
```

Graph Score：

```text
graph_score =
edge_weight
× confidence
× hop_decay
```

---

# 27. Graph Node → Associated Chunks

Graph Search 最终必须回到 chunk。

```sql
SELECT
    ec.chunk_id,
    ec.source_id,
    ec.relevance,
    gw.min_depth,
    gw.best_path_score

FROM graph_walk_result gw

JOIN graph_entity_chunk ec
  ON ec.entity_id = gw.entity_id;
```

最终：

```swift
struct GraphChunkHit {
    let chunkID: String

    let graphScore: Float

    let entityID: String

    let depth: Int

    let path: [GraphPathNode]
}
```

---

# 28. Graph Recall 的一个例子

知识库：

```text
David
   │ responsible_for
   ▼
ASR Module
   │ uses
   ▼
Qwen3-ASR
   │ compared_with
   ▼
Whisper
```

Query：

```text
David 负责的模块使用了什么模型？
```

Entity Extraction：

```text
David
```

Graph Search：

```text
David
  ↓ 1-hop
ASR Module
  ↓ 2-hop
Qwen3-ASR
```

Graph 返回关联 chunk：

```text
chunk_101
chunk_219
chunk_387
```

这些 chunk 即使与：

```text
“David 负责的模块使用了什么模型？”
```

embedding similarity 并不高，也能被召回。

---

# 29. Hybrid Search

完全复用 Vox Studio 现有 Search。

```text
Query
   │
   ├── BM25 Top 50
   │
   └── WeMM Vector Top 50
           │
           ▼
          RRF
           │
           ▼
        Top 30~40
```

Graph 不参与 WeMM vector index。

---

# 30. Recall Candidate Fusion

输入：

```text
Hybrid candidates
Graph candidates
```

不要简单：

```text
append
```

推荐统一成：

```swift
struct RecallCandidate {
    let chunkID: String

    let hybridScore: Float?
    let graphScore: Float?

    let recallSources: Set<RecallSource>

    let graphPaths: [GraphPath]
}
```

---

# 31. Merge + Dedup

按：

```text
chunk_id
```

去重。

若同一个 chunk 同时：

```text
Hybrid hit
+
Graph hit
```

保留两个 signal。

例如：

```json
{
  "chunk_id": "chunk_387",
  "hybrid_score": 0.72,
  "graph_score": 0.81,
  "recall_sources": [
    "vector",
    "bm25",
    "graph"
  ]
}
```

---

# 32. Recall Fusion Score

第一版 Graph 只负责扩充候选，不强行影响最终排序。

推荐：

```text
pre_rerank_score =
max(
    hybrid_score,
    graph_score × graph_weight
)
```

其中：

```text
graph_weight = 0.8
```

或者完全不做融合，只做 candidate union。

更推荐：

> **Reranker 负责最终统一打分。**

---

# 33. Candidate Budget

推荐：

```text
Hybrid Recall
Top 30

Graph Recall
Top 20

Union/Dedup
≈ 30~45

Rerank candidates
max 40
```

不要：

```text
Hybrid 50
+
Graph 100
→ 150 rerank
```

本地 Mac 会增加明显 latency。

---

# 34. CHUNK_RERANK

推荐：

```text
Qwen3-Reranker-0.6B
MLX 4-bit
```

输入：

```text
Query
+
Section Breadcrumb
+
Chunk
```

例如：

```text
Source: Vox Studio Architecture
Section: ASR > Model Selection

Qwen3-ASR is used as...
```

不要在 rerank 阶段默认加入：

```text
whole document summary
prev chunk
next chunk
```

避免污染 chunk relevance。

---

# 35. Graph Signal 是否进入 Reranker Prompt

默认：

```text
NO
```

不要告诉 Reranker：

```text
“This chunk was found through graph search.”
```

否则会引入 bias。

Reranker 应只判断：

```text
Query ↔ Passage relevance
```

---

# 36. Reranker Threshold

默认：

```yaml
reranker:
  candidates: 40
  threshold: 0.25
  top_k: 8
  minimum_keep: 3
```

0.25 是初始工程值，需要 Vox Studio 自己校准。

---

# 37. Context Merge

Rerank 后再进行上下文恢复。

优先级：

```text
Parent / Section
    >
Neighbor
    >
Doc Summary
```

流程：

```text
Top ranked chunks
      │
      ▼
Exact Dedup
      │
      ▼
Parent Context Recovery
      │
      ▼
Conditional Neighbor Expansion
      │
      ▼
Sequential Merge
      │
      ▼
Partial Overlap Removal
      │
      ▼
Evidence Blocks
```

---

# 38. Neighbor Expansion

不要无条件：

```text
prev + current + next
```

只在 chunk：

- 太短
- 有代词依赖
- 句子不完整
- ASR 对话上下文不完整

时扩展。

例如：

```text
“This was about twice as fast.”
```

必须补邻居。

---

# 39. Transcript 特殊策略

Vox Studio 有音视频 transcript。

Graph + Context Builder 对 transcript 推荐使用：

```text
time-window based neighbor
```

例如：

```yaml
transcript:
  context_before_seconds: 20
  context_after_seconds: 30
```

比：

```text
±1 chunk
```

更自然。

---

# 40. 最终 EvidenceBlock

```swift
struct EvidenceBlock {

    let id: String

    let sourceID: String
    let sourceType: SourceType

    let title: String

    let sectionBreadcrumb: String?

    let content: String

    let chunkIDs: [String]

    let rerankScore: Float

    let pageRange: ClosedRange<Int>?

    let timeRange: ClosedRange<Double>?

    let graphPaths: [GraphPath]
}
```

---

# 41. 给 LLM 的 Graph 信息

Graph path 本身可以作为辅助 metadata。

例如：

```text
Graph path:
David
→ RESPONSIBLE_FOR
ASR Module
→ USES
Qwen3-ASR
```

但：

> Graph path 不能替代原始 chunk 证据。

推荐 Prompt：

```text
Use graph paths only as navigation and relationship hints.
Treat the source passages as authoritative evidence.
```

---

# 42. LLM Prompt

```text
You are Vox Studio Knowledge Assistant.

Answer the user's question using only the supplied evidence.

Graph paths may explain why evidence was retrieved,
but factual claims must be supported by source passages.

Rules:

1. Do not invent missing relationships.
2. Prefer direct source evidence over inferred graph paths.
3. If multiple documents disagree, report the conflict.
4. Preserve exact model names, versions, commands,
   error codes, dates and numerical values.
5. Cite the supporting source for important factual claims.
6. If evidence is insufficient, say so clearly.
```

---

# 43. End-to-End Query Pseudocode

```swift
func answer(
    request: QARequest
) async throws -> AnswerStream {

    // 1
    let query =
        normalize(request.query)

    // 2
    let understanding =
        try await queryUnderstanding.run(
            query: query,
            history: request.history
        )

    // 3
    async let hybridHits =
        search.hybridSearch(
            query: understanding.retrievalQuery,
            scope: request.scope,
            vectorTopK: 50,
            keywordTopK: 50
        )

    // 4
    async let graphHits =
        graphRecall.search(
            entities: understanding.entities,
            intent: understanding.graphIntent,
            scope: request.scope
        )

    // 5
    let merged =
        recallFusion.merge(
            hybrid: try await hybridHits,
            graph: try await graphHits
        )

    // 6
    let candidates =
        merged
            .deduplicated()
            .prefix(40)

    // 7
    let ranked =
        try await reranker.rerank(
            query: understanding.retrievalQuery,
            candidates: candidates
        )

    // 8
    let selected =
        ranked
            .filter { $0.score >= 0.25 }
            .prefix(8)
            .withMinimumFallback(3)

    // 9
    let evidence =
        try contextBuilder.build(
            selected
        )

    // 10
    return answerLLM.stream(
        query: query,
        evidence: evidence
    )
}
```

---

# 44. Graph Search Service API

推荐抽象：

```swift
protocol GraphStore {

    func upsert(
        entities: [GraphEntity]
    ) async throws

    func upsert(
        relations: [GraphRelation]
    ) async throws

    func link(
        entityID: String,
        chunkID: String,
        sourceID: String
    ) async throws

    func resolveEntity(
        name: String
    ) async throws -> [GraphEntity]

    func neighbors(
        entityIDs: [String],
        maxDepth: Int,
        limit: Int
    ) async throws -> [GraphNodeHit]

    func chunkIDs(
        entityIDs: [String]
    ) async throws -> [GraphChunkLink]

    func removeSource(
        sourceID: String
    ) async throws
}
```

实现：

```text
SQLiteGraphStore
```

---

# 45. Swift / GRDB 推荐分层

```text
KnowledgeQAService
       │
       ├── QueryUnderstandingService
       │
       ├── SearchService
       │
       ├── GraphRecallService
       │       │
       │       ▼
       │   GraphStore
       │       │
       │       ▼
       │   SQLite / GRDB
       │
       ├── RerankerService
       │
       ├── ContextBuilder
       │
       └── AnswerLLMService
```

UI 不直接访问 SQLite。

---

# 46. Scope Filtering

Graph Search 必须尊重用户 Scope。

例如：

```text
current_file
current_project
selected_folders
knowledge_base
global
```

Entity → Chunk 后过滤：

```sql
SELECT ...
FROM graph_entity_chunk
WHERE entity_id IN (...)
AND source_id IN (...);
```

避免：

```text
用户问当前项目
Graph 却召回另一个项目的同名实体
```

---

# 47. 同名实体问题

例如：

```text
Apple
```

可能是：

```text
Company
Fruit
Project codename
```

解决策略：

```text
Entity Type
+
Source Scope
+
Nearby entities
+
Query context
```

不要只按 name 唯一化。

长期建议 entity key：

```text
normalized_name + entity_type
```

而不是：

```text
normalized_name only
```

---

# 48. Graph Path Ranking

对于每个 path：

```text
A
→ r1
B
→ r2
C
```

定义：

```text
path_score =
∏ edge_confidence
×
hop_decay(depth)
```

例如：

```text
A → B
confidence 0.9

B → C
confidence 0.8

2-hop decay = 0.65

path_score =
0.9 × 0.8 × 0.65
= 0.468
```

---

# 49. 多条 Path 到同一 Entity

例如：

```text
A → B → D

A → C → D
```

推荐：

```text
entity_graph_score =
max(path scores)
+
small multi-path bonus
```

第一版可以只：

```text
MAX(path_score)
```

保持简单。

---

# 50. Graph Recall Cache

Graph 查询很适合 cache。

Key：

```text
entity IDs
+
max depth
+
scope
+
graph version
```

例如：

```text
graph-search:
  qwen3-asr|vox-search
  depth=2
  scope=project-123
```

SQLite 本身已经很快，cache 主要减少 Entity Resolution 与重复 recursive query。

---

# 51. Rerank Cache

Key：

```text
query_hash
+
chunk_id
+
reranker_model_version
```

Graph Search 新增后，很多同一个 chunk 会反复进入候选。

Rerank cache 收益较高。

---

# 52. Data Ingestion 并发

推荐：

```text
foreground:
search / QA

background:
embedding
entity extraction
relation extraction
graph maintenance
```

Mac App 中：

```text
index priority < interactive QA
```

Entity extraction 不应该阻塞用户打开文件。

---

# 53. Graph Extraction Batch

不要每个 chunk 单独一次 LLM 请求。

建议：

```text
3~8 chunks
```

组成一个 logical section batch。

原因：

- Relation 往往跨 chunk
- 成本/延迟更低
- Entity consistency 更好

但最终 provenance 要映射回具体 chunk。

---

# 54. ASR / Meeting Ingestion

Transcript:

```text
Speaker
Timestamp
Text
```

Graph extraction 应保留 speaker。

例如：

```text
David:
We should use Qwen3-ASR for the meeting bot.
```

可以生成：

```text
David
  DISCUSSED
Qwen3-ASR
```

以及：

```text
Qwen3-ASR
  USED_BY
Meeting Bot
```

Provenance：

```text
meeting_2026_09_15
00:14:21 - 00:14:36
```

---

# 55. Entity Extraction 不要过度

错误做法：

```text
every noun → entity
```

会造成：

```text
Graph Explosion
```

应该提取：

> 值得跨 chunk / 跨文档连接的信息单元。

例如：

```text
Qwen3-ASR
Vox Studio
David
Meeting Bot
MLX
SQLite
```

而不是：

```text
performance
problem
service
result
information
```

这种普通名词。

---

# 56. Graph 数据质量评分

Relation 建议保留：

```text
confidence
```

例如：

```text
0.95
明确事实

0.70
上下文推断

0.40
弱推断
```

Graph Recall 默认过滤：

```text
confidence < 0.5
```

避免错误边扩散。

---

# 57. Graph Schema Version

务必保存：

```text
graph_schema_version
extractor_version
```

因为未来：

```text
Relation taxonomy
Prompt
Entity types
LLM model
```

都会升级。

Source state：

```text
schema_version=3
extractor=qwen3-4b-v2
```

如果 schema 升级，可以 background rebuild。

---

# 58. Graph DB 文件建议

例如：

```text
~/Library/Application Support/Vox Studio/
    Search/
        index.sqlite

    Graph/
        graph.sqlite
```

也可以和 Search 共用一个 SQLite DB。

推荐：

> **逻辑分表，物理上优先一个 SQLite DB。**

好处：

- transaction easier
- source deletion easier
- backup easier

但如果 Search engine 自己已经有独立 SQLite locking 策略，则 graph.sqlite 独立也合理。

---

# 59. SQLite 配置建议

Mac Desktop：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
```

使用 WAL 允许：

```text
background graph write
+
foreground graph read
```

并行。

---

# 60. 事务原则

一个 Source graph update：

```text
BEGIN

delete old source graph evidence

upsert entities

insert aliases

insert relations

insert entity_chunk

update source_state

COMMIT
```

必须 atomic。

避免 App crash 后：

```text
Search Index 是新版本
Graph 是半个旧版本
```

---

# 61. 是否要为 Entity 建 Embedding

第一版：

```text
NO
```

先使用：

```text
normalized name
+
alias
+
query context
```

如果发现：

```text
entity canonicalization
```

仍然是瓶颈，再复用 WeMM 为：

```text
entity name + short description
```

生成 embedding。

不要一开始再建复杂 Entity Vector DB。

---

# 62. Hybrid + Graph 的 Recall 角色

最终一定要保持：

```text
Hybrid Search
    │
    │ semantic / lexical
    ▼

Graph Search
    │
    │ relation / multi-hop
    ▼

Candidate Union
```

不要让 Graph 变成：

```text
Hybrid Search 失败后才用
```

因为 Graph 最有价值的正是：

> 找到 embedding similarity 不高但结构相关的内容。

---

# 63. Graph Recall 适合的问题

特别适合：

### Entity Relation

```text
OpenAI 和 Microsoft 有什么关系？
```

### Multi-hop

```text
David 负责的模块使用了哪些模型？
```

### Cross-document

```text
这个项目涉及的人分别讨论过哪些 ASR 模型？
```

### Timeline / Meetings

```text
我们之前在哪次会议里讨论过 Qwen3-ASR？
```

### Technical Dependency

```text
哪些模块依赖 WeMM Embedding？
```

---

# 64. Graph Recall 不擅长的问题

例如：

```text
“如何把 wav 转 mp3？”
```

如果知识库中就是一段明确说明：

```text
Hybrid Search
```

更直接。

Graph 不需要强行参与所有 query。

---

# 65. Metrics

必须记录：

```text
query_graph_enabled

query_entity_count

graph_nodes_visited

graph_chunks_returned

hybrid_chunks_returned

union_candidate_count

graph_only_chunks

hybrid_only_chunks

both_source_chunks

reranker_graph_survival_rate
```

特别推荐：

```text
graph_only_chunks_selected_by_reranker
```

这个指标。

它回答：

> Graph 到底有没有召回 Hybrid Search 找不到、但 Reranker 认为有价值的内容？

---

# 66. Graph Value Metric

定义：

```text
Graph Recall Lift
```

例如：

```text
最终 Top8 中
2 个 chunk
只能被 Graph 找到

Graph recall lift = 25%
```

如果长期：

```text
< 1%
```

说明图索引投入可能不值得。

---

# 67. Evaluation Dataset

建议建立：

```text
300~500 QA
```

其中至少：

```text
30%
Entity relationship

20%
Multi-hop

20%
Cross-document

20%
normal semantic QA

10%
negative / no answer
```

比较：

```text
Hybrid only

vs

Hybrid + Graph
```

指标：

```text
Recall@30
Recall@8 after rerank
nDCG@10
MRR
Answer accuracy
Citation precision
P95 latency
```

---

# 68. Latency Budget

本地 Mac 推荐目标：

```text
Query Understanding
30~150ms / local LLM dependent

Hybrid Search
< 50ms typical

SQLite Graph Search
< 10~30ms typical

Candidate Fusion
< 5ms

Qwen3 Reranker
主要 latency

Context Builder
< 20ms

LLM generation
streaming
```

Graph 本身不应该成为明显瓶颈。

---

# 69. 第一版推荐默认参数

```yaml
graph:
  enabled: true

  entity:
    max_query_entities: 5

  traversal:
    default_depth: 2
    max_depth: 3

    max_nodes_per_hop: 20
    max_total_nodes: 80

    min_edge_confidence: 0.50

    hop_decay:
      depth_1: 0.85
      depth_2: 0.65
      depth_3: 0.45

  recall:
    max_graph_chunks: 20

search:
  vector_top_k: 50
  keyword_top_k: 50

  hybrid_top_k: 30

fusion:
  rerank_candidate_limit: 40

reranker:
  model: Qwen3-Reranker-0.6B
  runtime: MLX
  quantization: 4bit

  threshold: 0.25
  top_k: 8
  minimum_keep: 3

context:
  parent_recovery: true
  neighbor_expansion: conditional
  sequential_merge: true

  max_context_tokens: 6000
```

---

# 70. Index Ingestion 完整流程

```text
Source Added / Updated
          │
          ▼
    Calculate content hash
          │
          ▼
  graph_source_state exists?
          │
       ┌──┴──┐
       │     │
      same   changed
       │     │
       ▼     ▼
      skip  Parse
              │
              ▼
             Chunk
              │
       ┌──────┴────────┐
       │               │
       ▼               ▼
 Existing Index    Graph Extraction
 BM25 + WeMM          │
                      ▼
               Entity + Relation
                      │
                      ▼
              Canonicalization
                      │
                      ▼
                  SQLite Tx
                      │
             ┌────────┼─────────┐
             ▼        ▼         ▼
          Entity   Relation   EntityChunk
                      │
                      ▼
             source_state update
```

---

# 71. Query 完整流程

```text
User
 │
 ▼
Raw Query
 │
 ▼
History / Scope
 │
 ▼
QUERY_UNDERSTAND
 │
 ├── Rewrite Query
 │
 ├── Extract Entities
 │
 └── Graph Intent
 │
 ├─────────────────────────────────┐
 │                                 │
 ▼                                 ▼
Hybrid Recall                   Graph Recall
 │                                 │
 ├─ Vector                         ├─ Resolve Entity
 ├─ BM25                           ├─ 1~3 hop
 └─ RRF                            └─ Entity→Chunk
 │                                 │
 └───────────────┬─────────────────┘
                 ▼
          Candidate Fusion
                 │
                 ▼
              Dedup
                 │
                 ▼
        Candidate Limit ≤ 40
                 │
                 ▼
       Qwen3 MLX Reranker
                 │
                 ▼
       Threshold + TopK + MMR
                 │
                 ▼
          Context Builder
                 │
         ┌───────┼─────────┐
         ▼       ▼         ▼
       Parent  Neighbor    Merge
                 │
                 ▼
           Evidence Blocks
                 │
                 ▼
                LLM
                 │
                 ▼
       Answer + Citations
```

---

# 72. 推荐模块边界

```text
VoxStudio
│
├── Indexing
│   ├── ChunkingService
│   ├── EmbeddingService
│   ├── SearchIndexer
│   │
│   └── GraphIngestionService
│       ├── EntityExtractor
│       ├── RelationExtractor
│       ├── EntityResolver
│       └── GraphStore
│
├── Search
│   ├── HybridSearchService
│   ├── GraphRecallService
│   └── RecallFusionService
│
├── QA
│   ├── QueryUnderstandingService
│   ├── RerankerService
│   ├── ContextBuilder
│   ├── AnswerabilityService
│   └── AnswerLLMService
│
└── Storage
    ├── ChunkStore
    ├── SearchIndex
    └── SQLiteGraphStore
```

---

# 73. 第一阶段实现顺序

## Phase 1

只做：

```text
Entity
EntityAlias
EntityChunk
```

Graph Search：

```text
Query Entity
→ Entity
→ chunks
```

先验证：

```text
Entity-based recall
```

有没有收益。

---

## Phase 2

增加：

```text
Relation
1-hop
2-hop
```

实现真正 Graph Recall。

---

## Phase 3

增加：

```text
Graph Intent
3-hop
path scoring
edge confidence
```

---

## Phase 4

增加：

```text
Graph QA visualization
```

例如在 Vox Studio UI 显示：

```text
David
→ responsible for
ASR
→ uses
Qwen3-ASR
```

但不是 v1 必需。

---

# 74. 最终推荐架构

对于 Vox Studio：

```text
Existing:
Hybrid Search
+
WeMM Embedding
+
Index

Add:
SQLite Graph Store
+
Entity / Relation Extraction
+
Graph Recall
+
Qwen3 Reranker
```

最终：

```text
                    Vox Studio Knowledge QA

                     User Query
                         │
                         ▼
                  Query Understanding
                         │
                   Entity Extraction
                         │
          ┌──────────────┴───────────────┐
          │                              │
          ▼                              ▼
   Hybrid Search                   SQLite Graph
 BM25 + WeMM Vector            Entity + 1~3 hop
          │                              │
          │                         graph nodes
          │                              │
          │                         chunk links
          │                              │
          └──────────────┬───────────────┘
                         ▼
                  Candidate Fusion
                         │
                    Dedup / Limit
                         │
                         ▼
            Qwen3-Reranker-0.6B
                  MLX 4-bit
                         │
                         ▼
                   Context Merge
                         │
                         ▼
                 Evidence Blocks
                         │
                         ▼
                        LLM
                         │
                         ▼
              Answer + Source Citation
```

---

# 75. 核心决策总结

| 决策 | 推荐 |
|---|---|
| Graph DB | SQLite |
| Swift DB layer | GRDB |
| Graph depth | 1~3 hop |
| 默认 depth | 2 |
| Graph 角色 | Recall augmentation |
| Hybrid Search | 保留现有 WeMM + BM25 |
| Candidate Fusion | Union + Dedup |
| Graph candidate | ≤20 |
| Final rerank candidates | ≤40 |
| Reranker | Qwen3-Reranker-0.6B MLX 4-bit |
| Reranker threshold | 0.25 起步 |
| Final TopK | 8 |
| Context | Parent > Neighbor > Summary |
| Graph path | 辅助 metadata，不作为唯一证据 |
| Entity Resolution | exact → alias → semantic |
| Update | Source-level transaction replacement |
| Local-first | 全流程可离线 |

---

# 76. 最重要的工程原则

整个方案最重要的不是“把 Graph DB 加进去”，而是保持三个层次彼此独立：

```text
Recall
    ↓
Hybrid + Graph
    ↓

Relevance
    ↓
Reranker
    ↓

Reasoning
    ↓
LLM
```

不要让：

```text
Graph Edge
```

自动变成：

```text
Answer Fact
```

Graph 的职责只是：

> **帮助系统找到那些单靠 BM25 / Embedding 不容易发现的相关证据。**

真正进入回答的内容仍然必须经过：

```text
Chunk
→ Reranker
→ Context Builder
→ LLM
```

这也是最适合 Vox Studio 本地 Knowledge Base QA 的 Graph-Augmented RAG 架构。
