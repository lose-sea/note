# 向量缓存与增量更新：别每次都全量重算

> 知识库有 50 万块，每天更新 200 块。
> 你每天重建一次索引——**每天重算 50 万条向量，花掉 99.96% 的冤枉钱。**

## 一、缓存的两个层次

```
① Embedding 缓存：文本 → 向量，避免重复调用 API
② 检索缓存：查询 → 结果，避免重复检索和生成
```

**第 ① 层是成本优化，第 ② 层是延迟优化。** 两个都值得做。

## 二、Embedding 缓存的设计

**缓存键的构造是关键。**

```python
def cache_key(text: str, model: str, **params) -> str:
    """键必须包含所有影响结果的参数"""
    payload = json.dumps({
        "text": text,
        "model": model,
        "dimensions": params.get("dimensions"),
        "normalize": params.get("normalize", True),
    }, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(payload.encode()).hexdigest()
```

**必须包含的维度**：

| 字段 | 为什么必须 |
|---|---|
| `text` | 内容本身 |
| **`model`** | 不同模型的向量不通 ⭐ |
| `dimensions` | 降维参数影响结果 |
| `normalize` | 归一化方式影响结果 |
| 特殊前缀 | 有些模型要求 `query:` / `passage:` 前缀 |

**最常见的 bug：只用了 text 做键。** 换模型之后，缓存返回了旧模型的向量——**向量空间不匹配，检索结果完全错乱**。

## 三、用 SQLite 做缓存（简单可靠）

```python
import sqlite3
import numpy as np
import hashlib
import time

class EmbeddingCache:
    def __init__(self, path: str = "embed_cache.db"):
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")        # 并发友好
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS embeddings (
                key        TEXT PRIMARY KEY,
                text_preview TEXT,
                vector     BLOB NOT NULL,
                dim        INTEGER NOT NULL,
                model      TEXT NOT NULL,
                created_at REAL NOT NULL,
                hit_count  INTEGER DEFAULT 0
            )
        """)
        self.conn.execute("CREATE INDEX IF NOT EXISTS idx_model ON embeddings(model)")
        self.conn.commit()
        self.hits = 0
        self.misses = 0

    def get(self, text: str, model: str, **params) -> np.ndarray | None:
        k = cache_key(text, model, **params)
        row = self.conn.execute(
            "SELECT vector, dim FROM embeddings WHERE key = ?", (k,)
        ).fetchone()
        if row:
            self.hits += 1
            self.conn.execute(
                "UPDATE embeddings SET hit_count = hit_count + 1 WHERE key = ?", (k,)
            )
            return np.frombuffer(row[0], dtype=np.float32).reshape(row[1])
        self.misses += 1
        return None

    def put(self, text: str, model: str, vector: np.ndarray, **params):
        k = cache_key(text, model, **params)
        v = np.asarray(vector, dtype=np.float32)
        self.conn.execute(
            "INSERT OR REPLACE INTO embeddings VALUES (?, ?, ?, ?, ?, ?, 0)",
            (k, text[:200], v.tobytes(), v.shape[0], model, time.time()),
        )
        self.conn.commit()

    def stats(self) -> dict:
        total = self.hits + self.misses
        return {
            "hits": self.hits,
            "misses": self.misses,
            "hit_rate": self.hits / total if total else 0,
            "rows": self.conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0],
        }
```

**用 BLOB 存向量比 JSON 快得多**——`np.frombuffer` 是零拷贝的。

**性能参考**：

```
读取：约 0.1ms（SQLite 本地）
API 调用：约 200ms
→ 缓存命中快 2000 倍
```

## 四、缓存键选择：整块 vs 句级

**整块缓存 vs 句级缓存，命中率差别很大。**

**场景**：一个段落里改了一个字。

```
整块缓存：
  段落哈希变了 → 未命中 → 重新向量化整段

句级缓存：
  只有那一句的哈希变了 → 其他句子命中 → 只向量化一句
```

**实现（句级）**：

```python
def embed_with_sentence_cache(sentences: list[str], model: str, cache: EmbeddingCache):
    vecs = []
    for s in sentences:
        v = cache.get(s, model)
        if v is None:
            v = embed_api([s], model)[0]
            cache.put(s, model, v)
        vecs.append(v)
    return np.mean(vecs, axis=0)      # 句子向量平均得到段落向量
```

**但注意**：句级缓存的段落向量 = 句子向量平均，**和"整段一起向量化"的结果不一样**。

**选择**：

| 方式 | 命中率 | 语义质量 |
|---|---|---|
| 整块 | 低 | 高（上下文完整） |
| 句级聚合 | 高 | 中（丢失跨句上下文） |

**推荐：块级检索 + 块级缓存**。命中率虽低，但语义质量更重要。**句子级缓存适合"文本量大且改动频繁"的场景。**

## 五、增量更新：三个层次

**① 文档级**

```python
def sync_documents(source_dir: str, indexer, state: dict):
    """按文件 mtime + size 判断是否变化"""
    current = {}
    for p in Path(source_dir).rglob("*.md"):
        current[str(p)] = {"mtime": p.stat().st_mtime, "size": p.stat().st_size}

    for path, info in current.items():
        old = state.get(path)
        if old is None:
            indexer.add(path)                     # 新增
        elif old != info:
            indexer.update(path)                  # 修改
        # 其他情况：未变化，跳过

    for path in state:
        if path not in current:
            indexer.delete_by_source(path)        # 删除

    return current
```

**用 `mtime + size` 做判断，成本极低**。但**不可靠**（有人可能改回原内容）。

**更可靠的是内容哈希**：

```python
def file_hash(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
```

**推荐组合：先比 mtime + size（快），可疑的再比哈希（准）。**

**② 块级**

文档变了，不是所有块都变了。**块级增量能把更新粒度压到最小**：

```python
class ChunkLevelIndexer:
    def __init__(self, vectorstore, embeddings, state_file="chunk_state.json"):
        self.vs, self.emb = vectorstore, embeddings
        self.state_file = Path(state_file)
        self.state = json.loads(self.state_file.read_text()) if self.state_file.exists() else {}

    def sync(self, source: str, new_chunks: list[Document]):
        old_ids = {cid for cid, s in self.state.items() if s["source"] == source}

        to_add, to_del = [], []
        new_ids = set()

        for i, c in enumerate(new_chunks):
            cid = make_stable_id(source, i, c.page_content)
            c.metadata["chunk_id"] = cid
            new_ids.add(cid)

            if cid not in self.state:
                to_add.append(c)

        to_del = list(old_ids - new_ids)

        if to_del:
            self.vs.delete(ids=to_del)
        if to_add:
            self.vs.add_documents(to_add)

        for c in new_chunks:
            self.state[c.metadata["chunk_id"]] = {
                "source": source,
                "hash": content_hash(c.page_content),
            }
        self.state_file.write_text(json.dumps(self.state))

        print(f"{source}: +{len(to_add)} -{len(to_del)} (共 {len(new_chunks)} 块)")
```

**`make_stable_id` 必须稳定**：

```python
def make_stable_id(source: str, index: int, text: str) -> str:
    return f"{source}#{index}#{hashlib.md5(text.encode()).hexdigest()[:8]}"
```

**注意"位置 + 内容哈希"的组合**：

- 只用位置 → 内容变了但位置没变，id 相同，无法识别变更；
- 只用内容 → 位置变了（插入了一段），后面的块 id 全变，全量重算；
- **位置 + 内容 → 两边都稳定**。

## 六、批量更新的幂等性

**同步任务可能被重复执行**（重试、并发）。要保证幂等：

```python
def idempotent_sync(source: str, chunks: list[Document]):
    # 用"source + 内容哈希"作为幂等键
    sync_id = f"{source}#{hashlib.sha256(json.dumps([c.page_content for c in chunks]).encode()).hexdigest()[:16]}"

    if already_synced(sync_id):
        log.info("该版本已同步，跳过", source=source)
        return

    do_sync(source, chunks)
    mark_synced(sync_id)
```

## 七、缓存失效策略

**缓存不能无限增长。** 三种清理策略：

**① 按时间**

```python
def evict_old(cache: EmbeddingCache, days: int = 90):
    cutoff = time.time() - days * 86400
    cache.conn.execute("DELETE FROM embeddings WHERE created_at < ?", (cutoff,))
    cache.conn.commit()
```

**② 按命中率**（低频项先删）

```python
def evict_never_hit(cache: EmbeddingCache, keep: int = 1_000_000):
    count = cache.conn.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    if count <= keep:
        return
    cache.conn.execute("""
        DELETE FROM embeddings WHERE key IN (
            SELECT key FROM embeddings ORDER BY hit_count ASC, created_at ASC
            LIMIT ?
        )
    """, (count - keep,))
```

**③ 按模型**（换模型后清空旧模型的缓存）

```python
def evict_model(cache: EmbeddingCache, model: str):
    cache.conn.execute("DELETE FROM embeddings WHERE model = ?", (model,))
```

## 八、检索结果缓存

**第二层缓存：相同查询直接返回结果。**

```python
import redis
import json

r = redis.Redis(decode_responses=True)

def cached_retrieve(query: str, retriever, ttl: int = 3600):
    key = f"retrieval:{hashlib.md5(query.encode()).hexdigest()}"

    cached = r.get(key)
    if cached:
        return json.loads(cached)

    docs = retriever.invoke(query)
    r.setex(key, ttl, json.dumps([d.model_dump() for d in docs], ensure_ascii=False))
    return docs
```

**注意**：

- **TTL 要短**（1 小时以内）——知识库可能更新；
- **查询要归一化**（去空格、统一大小写）——否则"退款？"和"退款"是两个 key；
- **要能主动失效**——文档更新时清掉相关缓存。

**主动失效的做法**：

```python
def invalidate_by_source(source: str):
    """文档更新时清掉相关缓存"""
    pattern = f"retrieval:*"
    for key in r.scan_iter(match=pattern, count=100):
        cached = r.get(key)
        if cached and source in cached:
            r.delete(key)
```

**这种"扫描 + 匹配"成本高**。更好的做法是**维护一个反向索引**（source → 相关查询），但复杂度上去了。

**实际项目中最常见的做法：用短 TTL（15 分钟）**，让缓存自然过期。

## 九、几个坑

**① 缓存键必须包含模型。**
这是最高频的错误。

**② 向量存 float32 而不是 float64。**
float64 会让存储翻倍，且精度提升无意义。

```python
v.astype(np.float32).tobytes()          # ✅
v.astype(np.float64).tobytes()          # ❌ 浪费一倍
```

**③ SQLite 要开 WAL。**
默认模式在多线程下会锁表。`PRAGMA journal_mode=WAL` 让读写并发。

**④ 别把缓存放在内存里。**
进程重启就没了。**用 SQLite 或 Redis 持久化**。

**⑤ 缓存的"内容"要能追查。**
存 `text_preview`（前 200 字），出问题时能知道这个 key 对应什么内容。

**⑥ 断点续跑和缓存是两回事。**
缓存是"这条数据算过没有"，断点是"这个批次处理到哪了"。**两个都要有。**

**⑦ 别缓存"随机性输出"的结果。**
如果检索用了随机采样或 LLM 改写，结果不稳定，缓存会导致行为不一致。

## 十、收益量化

一个典型的知识库同步任务：

```
规模：50 万块
每日更新：200 块（0.04%）
```

| 方案 | 每日 API 调用 | 每日成本 | 耗时 |
|---|---|---|---|
| 全量重算 | 500,000 | 100% | 3 小时 |
| 文档级增量 | ~2,000 | 0.4% | 1 分钟 |
| **块级增量 + 缓存** | **~250** | **0.05%** | **15 秒** |

**成本降到 1/2000。**

## 十一、小结

```python
# 两层缓存
cache = EmbeddingCache()          # 文本 → 向量
r = redis.Redis()                 # 查询 → 结果

# 增量更新（三级粒度）
文档级（mtime + hash）→ 块级（稳定 ID）→ 内容级（句子哈希）
```

五条原则：

```
1. 缓存键必须包含 model（最容易漏）
2. 向量存 float32，SQLite 开 WAL
3. 增量更新要三级粒度：文档 → 块 → 内容
4. chunk_id 必须稳定（位置 + 内容哈希）
5. 有清理策略（按时间 / 按命中率 / 按模型）
```

**一句话：缓存和增量是"用空间换时间、用复杂度换成本"的经典权衡。** 它们的实现不难，但**每一个细节都有坑**——尤其是缓存键的设计，错一个字段就会导致整个向量库的检索质量崩掉。
