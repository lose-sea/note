# LangChain4j：Java 团队的 LLM 应用第一站

如果你的团队是 Java 栈——Spring Boot 一把梭、Maven 仓管得明明白白、SDK 要求类型安全——那么 LangChain 的 Python 出身会让你犹豫：要么引入 Python 微服务做双语言架构，要么看看 Java 生态自己的答案。LangChain4j 就是后者：LangChain 的 Java 实现，把 LLM 应用开发纳入了 Java 工程体系。这篇文章讲它是什么、怎么用、和 Python 版是什么关系，以及 Java 团队的真实上手路径。

## LangChain4j 是什么

一句话：**面向 Java 的 LLM 应用编排框架**，2023 年初启动，现在已经是 Apache 孵化项目之外最活跃的 JVM LLM 库之一。它做了这些事：

- **统一模型接口**：OpenAI、通义千问、本地 Ollama、HuggingFace……一个 `ChatLanguageModel` 接口打天下，换模型改一行。
- **AI Services**：声明式接口 + 注解/默认方法，把"提示词+工具+记忆+护栏"封装成一个 Java 接口，调用方像调本地方法一样调 AI。
- **RAG 全家桶**：文档加载、切分、embedding、向量库、检索、重排的完整管道，向量库支持 Qdrant、Milvus、PGVector、Redis 等一排。
- **工具调用**：Java 方法直接用 `@Tool` 暴露给模型，参数解析交给框架。
- **MCP 支持**：较新的版本开始支持 Model Context Protocol，能挂外部 MCP 工具服务器。

它和 Python 的 LangChain/LangGraph 没有代码共享，是平行项目，理念相通（链、工具、记忆），语法各自 idiomatic。

## 十分钟跑通第一个例子

Maven 项目引入两个 starter：

```xml
<dependency>
    <groupId>dev.langchain4j</groupId>
    <artifactId>langchain4j-open-ai</artifactId>
    <version>1.0.0</version>
</dependency>
```

最基础的直接调用：

```java
ChatLanguageModel model = OpenAiChatModel.builder()
    .apiKey(System.getenv("OPENAI_API_KEY"))
    .modelName("gpt-4o-mini")
    .temperature(0.0)
    .build();

String answer = model.chat("用一句话解释 BM25 算法");
```

注意最后那个 `temperature(0.0)`：Java 工程文化对确定性的执念，从这行代码就开始体现。

再看 LangChain4j 的招牌能力——AI Services：

```java
interface TravelAssistant {
    @SystemMessage("你是差旅助手，只根据工具返回作答，不要编造")
    String plan(@UserMessage String request);

    @Tool("根据日期查询城市天气")
    String checkWeather(@P("城市名") String city, @P("日期 yyyy-MM-dd") String date);
}

TravelAssistant assistant = AiServices.builder(TravelAssistant.class)
    .chatLanguageModel(model)
    .tools(new WeatherService())
    .build();

String reply = assistant.plan("帮我看看后天去上海出差要不要带伞");
```

对 Java 团队来说这个体验是"原生的"：接口定义行为、注解配提示词、外部服务实现、框架负责编排。IDE 补全、类型检查、重构一把全支持，测试直接 mock 接口。这种**把 AI 能力编译进类型系统**的思路，是 Python 版本给不了的。

工具方法注意两个注解：`@Tool` 的描述会进模型的工具 schema，写清楚比写简短重要；`@P` 给参数加描述，模型才填得对。`WeatherService` 就是个普通 Spring Bean，方法名见文知意：

```java
@Component
public class WeatherService {
    public String checkWeather(String city, String date) {
        // 调内部天气服务，返回结构化文本
        return weatherClient.get(city, LocalDate.parse(date)).toString();
    }
}
```

## RAG 也不含糊

索引构建和问答两侧都齐：

```java
// 索引：加载 → 切分 → embedding → 入库
EmbeddingStore<TextSegment> store = new InMemoryEmbeddingStore<>();
EmbeddingModel embedding = new BgeSmallZhV15QuantizedEmbeddingModel(); // 本地模型，无需 API

IngestionPipeline pipeline = IngestionPipeline.builder()
    .documentSplitter(DocumentSplitters.recursive(500, 50))
    .embeddingModel(embedding)
    .embeddingStore(store)
    .build();
pipeline.run(FileSystemDocumentLoader.loadDocuments("docs/"));

// 问答：默认就带检索
ContentRetriever retriever = EmbeddingStoreContentRetriever.builder()
    .embeddingStore(store).embeddingModel(embedding).maxResults(5).build();

interface DocQA { String answer(String question); }

DocQA qa = AiServices.builder(DocQA.class)
    .chatLanguageModel(model)
    .contentRetriever(retriever)   // 挂上检索器，检索结果自动注入 prompt
    .build();
```

本地 embedding 那行值得划重点：`BgeSmallZhV15QuantizedEmbeddingModel` 是 onnx 量化的中文小模型，jar 包级集成，不需要 Python 服务。**政务、金融内网场景没法调外部 API，这种全本地栈往往是关键决策点**。

## 工程化落地：和 Spring Boot 的合流

 starter 直接把这个框架变成 Spring 全家桶的一部分：

```xml
<dependency>
    <groupId>dev.langchain4j</groupId>
    <artifactId>langchain4j-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

```yaml
langchain4j:
  open-ai:
    chat-model:
      api-key: ${OPENAI_API_KEY}
      model-name: gpt-4o-mini
```

然后 AI Services 可以声明为 Bean，工具类自动注入：

```java
@Configuration
public class AiConfig {
    @Bean
    TravelAssistant travelAssistant(ChatLanguageModel model, WeatherService weather) {
        return AiServices.builder(TravelAssistant.class)
            .chatLanguageModel(model)
            .tools(weather)
            .build();
    }
}
```

Java 团队熟悉的一切都回来了：配置外置、依赖注入、`@Service` 接口注入 Controller、YAML 管环境差异、Actuator 加健康检查。下一篇专门讲这套 Spring Boot 集成怎么搭起来。

## 它和 Python 版怎么选

这是 Java 团队决策时的真实纠结，摆事实：

| 维度 | LangChain4j (Java) | Python LangChain/LangGraph |
|---|---|---|
| 生态成熟度 | 追赶中，主流厂商/向量库已覆盖 | 最全，新特性首发地 |
| 特性同步 | 慢 0~数月，核心功能有 | 最新 |
| 技术栈契合 | Java 团队原生体验 | 需引入 Python 服务或双栈 |
| 部署运维 | 融入现有 JVM 体系 | 独立 Python 服务 |
| Agent 编排能力 | AI Services + 早期图编排 | LangGraph 完整状态机 |
| 团队学习成本 | Java 开发者低 | 高（新语言 + 新范式） |

决策规则很直白：**核心系统在 JVM 上、团队没有 Python 存量、需求是标准 RAG/工具调用/单 Agent → LangChain4j 能吃掉大部分需求；重度 Agent 编排、要跟 LangGraph/LangSmith 生态联动、团队 Python 熟练 → Python 栈。**

折中路线也存在：LangChain4j 跑主干，复杂 Agent 用 Python 写侧面服务，两边用 HTTP/MCP 通信。这是不少金融团队的实际形态。

## 已知短板，提前打预防针

- **复杂 Agent 编排弱于 LangGraph**。多 Agent 交接、人工介入中断、状态回放这些，Python 版目前更深。1.x 版本在图编排上有官方模块但生态案例少。
- **文档质量参差**。核心 API 文档全，但像"工具调用最佳实践"这类实战内容远不如 Python 社区丰富，很多时候要读源码。
- **版本迁移快**。0.x 到 1.0 期间 breaking change 不少，升级要预留测试时间。好消息是 1.0 后 API 稳定了。
- **模型覆盖率永远差半拍**。新模型发布，Python SDK 先上，LangChain4j 通常几周跟上——对追新模型的人是痛点，对求稳的人是优点。

## 结语

LangChain4j 给 Java 团队的，不是"又一个要学的框架"，而是"把 LLM 能力装进现有工程体系"的一条正道。声明式 AI Services、starter 生态、本地 embedding 支持，每一个都对在 Java 团队的痛点上。下一篇讲 Spring Boot 集成的完整工程化配置：连接池、可观测、流式输出、测试怎么写，把一个 demo 变成能进生产的模块。
