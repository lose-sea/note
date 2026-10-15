# 批量向量化：100 万条数据怎么在 2 小时内跑完

> 一条一条调 embedding API：
> 每次 200ms，100 万条 = 55 小时。**还得算上被限流的时间。**
>
> 批量化之后：**2 小时跑完，成本还更低。**

## 一、批量化的三重收益

| 收益 | 说明 |
|---|---|
| **速度** | 一次请求处理多条，网络往返减少 |
| **成本** | 部分服务商按请求计费，批量更省 |
| **稳定性** | 请求数减少，触发限流的概率降低 |

**单条 vs 批量（1000 条，每次 API 200ms）**：

```
单条：1000 × 200ms = 200 秒
批量（每批 100 条）：10 × 250ms = 2.5 秒
```

**80 倍的差距。**

## 二、批量的两种层次

**① API 层批量**：一次请求传多个文本

```python
# OpenAI 的 embedding API 原生支持批量
response = client.embeddings.create(
    input=["文本1", "文本2", ..., "文本100"],    # 最多 2048 条
    model="text-embedding-3-small",
)
vectors = [d.embedding for d in response.data]
```

**② 并发层批量**：多个批量请求并行

```python
import asyncio

async def embed_all(texts: list[str], batch_size: int = 100, concurrency: int = 5):
    """分批 + 并发"""
    batches = [texts[i:i+batch_size] for i in range(0, len(texts), batch_size)]
    sem = asyncio.Semaphore(concurrency)

    async def process(batch):
        async with sem:
            return await embed_batch(batch)

    results = await asyncio.gather(*[process(b) for b in batches])
    return [v for r in results for v in r]
```

**两个层次配合**：批量降低单次请求数，并发提升吞吐。

**并发数的确定**：

```
concurrency = rate_limit_rpm / (60 / avg_latency_seconds)

例：限流 3000 RPM，平均延迟 0.3 秒
    3000 / (60 / 0.3) = 3000 / 200 = 15
```

**从保守值开始（5），逐步提高，观察是否触发 429。**

## 三、限流处理：必须有的三件套

**① 令牌桶限流**

```python
import time
import threading

class TokenBucket:
    def __init__(self, rate: float, capacity: int):
        self.rate = rate                  # 每秒补充的令牌数
        self.capacity = capacity
        self.tokens = capacity
        self.lock = threading.Lock()
        self.last = time.monotonic()

    def acquire(self, n: int = 1, timeout: float = 60) -> bool:
        deadline = time.monotonic() + timeout
        while True:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(self.capacity,
                                  self.tokens + (now - self.last) * self.rate)
                self.last = now
                if self.tokens >= n:
                    self.tokens -= n
                    return True
            if time.monotonic() > deadline:
                return False
            time.sleep(0.01)
```

**② 指数退避重试**

```python
import random

async def embed_with_retry(batch, max_attempts: int = 5):
    for attempt in range(max_attempts):
        try:
            return await embed_batch(batch)
        except RateLimitError as e:
            if attempt == max_attempts - 1:
                raise
            # 优先听服务端的 Retry-After
            wait = get_retry_after(e) or min(2 ** attempt, 30)
            wait += random.random()          # 抖动，避免惊群
            await asyncio.sleep(wait)
```

**③ 自适应并发**

```python
class AdaptiveLimiter:
    """根据 429 出现的频率动态调整并发"""
    def __init__(self, initial: int = 5, min_c: int = 1, max_c: int = 30):
        self.concurrency = initial
        self.min_c, self.max_c = min_c, max_c
        self.success_streak = 0

    def on_success(self):
        self.success_streak += 1
        if self.success_streak >= 50:            # 连续成功 50 次
            self.concurrency = min(self.concurrency + 1, self.max_c)
            self.success_streak = 0

    def on_rate_limit(self):
        self.concurrency = max(self.concurrency // 2, self.min_c)
        self.success_streak = 0
```

**自适应比固定并发好**——服务端的限流策略可能随时间变化。

## 四、文本超长的处理

**模型有 token 上限**（如 8191），超了会报错或被截断。

```python
import tiktoken

enc = tiktoken.get_encoding("cl100k_base")
MAX_TOKENS = 8000        # 留余量

def truncate_for_embedding(text: str, max_tokens: int = MAX_TOKENS) -> str:
    tokens = enc.encode(text)
    if len(tokens) <= max_tokens:
        return text
    return enc.decode(tokens[:max_tokens])
```

**但"截断"会丢信息。更好的做法是切分后分别向量化**：

```python
def embed_long_text(text: str, embeddings) -> np.ndarray:
    """长文本切分后向量化，再取平均"""
    parts = split_by_tokens(text, max_tokens=2000)
    vecs = embeddings.embed_documents(parts)
    return np.mean(vecs, axis=0)          # 平均池化
```

**三种聚合方式**：

| 方式 | 说明 | 适用 |
|---|---|---|
| 平均 | 简单，但会稀释 | 通用 |
| 加权平均 | 按段落重要性加权 | 有结构 |
| 拼接后重编码 | 最准但要多一次调用 | 高质量要求 |

**注意：`text-embedding-3-*` 支持 8191 token，但中文约 1 字 = 1~1.5 token**，所以中文文本的安全长度约 5000~6000 字。

## 五、增量更新：别全量重算

**文档只改了 1%，不该重算 100%。**

```python
import hashlib

def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]

class IncrementalIndexer:
    def __init__(self, vectorstore, embedding_service, state_file="index_state.json"):
        self.vs = vectorstore
        self.emb = embedding_service
        self.state = self._load_state(state_file)
        self.state_file = state_file

    def _load_state(self) -> dict:
        """记录每个 chunk_id 的内容哈希"""
        if Path(self.state_file).exists():
            return json.loads(Path(self.state_file).read_text())
        return {}

    def sync(self, chunks: list[Document]):
        to_add, to_update, to_delete = [], [], []

        new_state = {}
        for c in chunks:
            cid = c.metadata["chunk_id"]
            h = content_hash(c.page_content)
            new_state[cid] = h

            if cid not in self.state:
                to_add.append(c)
            elif self.state[cid] != h:
                to_update.append(c)

        # 旧有新无 → 删除
        to_delete = [cid for cid in self.state if cid not in new_state]

        print(f"新增 {len(to_add)}，更新 {len(to_update)}，删除 {len(to_delete)}")

        if to_add:
            self.vs.add_documents(to_add)
        if to_update:
            self.vs.delete(ids=[c.metadata["chunk_id"] for c in to_update])
            self.vs.add_documents(to_update)
        if to_delete:
            self.vs.delete(ids=to_delete)

        self.state = new_state
        Path(self.state_file).write_text(json.dumps(new_state))
```

**关键点：用 `chunk_id` 做稳定标识**。如果每次分块的 id 都变（如用随机 uuid），增量更新就失效了。

**稳定的 chunk_id 生成**：

```python
def make_chunk_id(source: str, index: int, text: str) -> str:
    """来源 + 序号 + 内容哈希，保证稳定性"""
    return f"{source}#{index}-{content_hash(text)}"
```

## 六、断点续跑：大任务必须能中断恢复

100 万条的东西，跑一半挂了不能从头来。

```python
class ResumableIndexer:
    def __init__(self, checkpoint_file="embed_progress.json"):
        self.ckpt_file = Path(checkpoint_file)
        self.progress = self._load()

    def _load(self) -> dict:
        if self.ckpt_file.exists():
            return json.loads(self.ckpt_file.read_text())
        return {"done_batches": [], "vectors": []}

    async def run(self, batches: list[list[str]]):
        for i, batch in enumerate(batches):
            if i in self.progress["done_batches"]:
                continue                       # 跳过已完成
            vectors = await embed_with_retry(batch)
            self.progress["vectors"].extend(vectors)
            self.progress["done_batches"].append(i)
            self._save()                       # 每批存一次
            if i % 10 == 0:
                print(f"进度 {i}/{len(batches)}")

    def _save(self):
        self.ckpt_file.write_text(json.dumps(self.progress))
```

**存盘频率要平衡**：太频繁（每条）I/O 重；太稀疏（每 1000 批）丢数据多。**每批存一次**是合理的。

## 七、成本估算与优化

```python
PRICING = {"text-embedding-3-small": 0.02, "text-embedding-3-large": 0.13}  # 元 / 1M token

def estimate_cost(texts: list[str], model: str):
    total_tokens = sum(len(enc.encode(t)) for t in texts)
    cost = total_tokens / 1e6 * PRICING[model]
    print(f"总 token：{total_tokens:,}")
    print(f"预估成本：{cost:.2f} 元")
    print(f"（{len(texts)} 条，平均 {total_tokens/len(texts):.0f} token/条）")
    return cost
```

**优化手段**：

| 手段 | 省多少 |
|---|---|
| 用小的模型 | 6.5 倍（small vs large） |
| 降维（`dimensions=512`） | 无成本变化（但省存储） |
| **缓存不重复算** | 取决于重复率 ⭐ |
| 缩短文本 | 直接按比例 |
| 批量 | 部分服务商按请求计费 |

**缓存是第一优先**——见下一节。

## 八、缓存：最有效的成本优化

```python
import hashlib
import sqlite3

class EmbeddingCache:
    def __init__(self, db_path="embed_cache.db"):
        self.conn = sqlite3.connect(db_path)
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS cache (
                hash TEXT PRIMARY KEY,
                text TEXT,
                vector BLOB,
                model TEXT,
                created_at REAL
            )
        """)

    def get(self, text: str, model: str) -> np.ndarray | None:
        h = hashlib.sha256(f"{model}:{text}".encode()).hexdigest()
        row = self.conn.execute(
            "SELECT vector FROM cache WHERE hash = ?", (h,)
        ).fetchone()
        if row:
            return np.frombuffer(row[0], dtype=np.float32)
        return None

    def put(self, text: str, model: str, vector: np.ndarray):
        h = hashlib.sha256(f"{model}:{text}".encode()).hexdigest()
        self.conn.execute(
            "INSERT OR REPLACE INTO cache VALUES (?, ?, ?, ?, ?)",
            (h, text[:200], vector.astype(np.float32).tobytes(), model, time.time()),
        )
        self.conn.commit()
```

**缓存键必须带 `model`**——换模型后不能复用旧向量。

**实测命中率**：

```
文档更新场景：命中率 90%+（只有少数改动的块要重算）
重复文档场景：命中率 60~80%
全新数据：命中率 0%
```

**文档频繁更新的知识库，缓存能省 80% 以上的成本。**

## 九、一个完整的批量管线

```python
async def build_index_pipeline(
    chunks: list[Document],
    embeddings,
    vectorstore,
    batch_size: int = 100,
    concurrency: int = 8,
    use_cache: bool = True,
):
    limiter = TokenBucket(rate=50, capacity=100)
    cache = EmbeddingCache() if use_cache else None

    # 1. 查缓存
    pending, cached_vecs, cached_idx = [], {}, []
    for i, c in enumerate(chunks):
        v = cache.get(c.page_content, MODEL) if cache else None
        if v is not None:
            cached_vecs[i] = v
        else:
            pending.append((i, c.page_content))

    print(f"缓存命中 {len(cached_vecs)}/{len(chunks)}")

    # 2. 批量算未命中的
    new_vecs = {}
    for start in range(0, len(pending), batch_size):
        batch = pending[start:start + batch_size]
        limiter.acquire(len(batch))
        vecs = await embed_with_retry([t for _, t in batch])
        for (orig_i, text), v in zip(batch, vecs):
            new_vecs[orig_i] = v
            if cache:
                cache.put(text, MODEL, v)
        print(f"已处理 {start + len(batch)}/{len(pending)}")

    # 3. 按原顺序合并
    all_vecs = [cached_vecs.get(i) or new_vecs[i] for i in range(len(chunks))]

    # 4. 写入向量库
    vectorstore.add_embeddings(
        texts=[c.page_content for c in chunks],
        embeddings=[v.tolist() for v in all_vecs],
        metadatas=[c.metadata for c in chunks],
    )
```

## 十、小结

```python
# 核心三件套
limiter   = TokenBucket(rate=50, capacity=100)      # 限流
cache     = EmbeddingCache()                        # 缓存
semaphore = asyncio.Semaphore(8)                    # 并发控制
```

五条原则：

```
1. 批量 + 并发（两个层次一起用）
2. 令牌桶限流 + 指数退避 + 自适应并发
3. 超长文本切分后聚合，别直接截断
4. 增量更新（内容哈希）+ 断点续跑
5. 缓存是第一成本优化手段
```

**一句话：批量向量化不是"写个 for 循环加上并发"，而是一套完整的工程能力**——限流、重试、缓存、增量、断点，缺一个就会在真实数据量上出问题。
