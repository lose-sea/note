# Spring Boot 集成 LangChain4j：从 demo 到生产模块

上一篇文章我们尝了 LangChain4j 的声明式接口，但"能跑"和"能进生产"之间隔着一整套 Spring 工程化改造：配置外置、流式输出、连接管理、可观测、测试。这篇就按一个真实生产模块的样子，把这些逐条落地。

## 依赖与配置骨架

```xml
<dependency>
    <groupId>dev.langchain4j</groupId>
    <artifactId>langchain4j-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
<dependency>
    <groupId>dev.langchain4j</groupId>
    <artifactId>langchain4j-open-ai-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

```yaml
langchain4j:
  open-ai:
    chat-model:
      api-key: ${OPENAI_API_KEY}
      model-name: ${LLM_MODEL:gpt-4o-mini}
      temperature: 0.0
      max-tokens: 1024
      timeout: 30s
      max-retries: 2
      log-requests: ${LLM_LOG_REQ:false}
      log-responses: ${LLM_LOG_RESP:false}
```

starter 会自动装配 `ChatLanguageModel`、`StreamingChatLanguageModel`（如果依赖里配了流式模型）、embedding 模型等。两个细节：**timeout 和 max-retries 一定要显式配**——starter 默认有兜底值，但 LLM API 的默认超时对 Agent 场景往往偏长，Agent 单次迭代等 60s 才超时会拖垮整个请求；**log-requests 默认关**是对的，请求里全是用户数据，生产开这玩意等于往日志里灌隐私，要开也只开 debug 环境。

## 声明式 Bean 注册 AI Services

starter 支持把接口直接注册成 Bean：

```java
@Configuration
public class AiConfig {

    @Bean
    TravelAssistant travelAssistant(
            ChatLanguageModel chatModel,
            List<Object> tools) {           // 注入所有 @Component 工具
        return AiServices.builder(TravelAssistant.class)
            .chatLanguageModel(chatModel)
            .tools(tools)
            .chatMemory(MessageWindowChatMemory.withMaxMessages(20))
            .build();
    }
}
```

`List<Object> tools` 是个技巧：Spring 把所有标注了 `@Tool` 方法的 Bean 自动收集进来，加新工具只要写个新 `@Component`，配置零改动。多 Agent 系统里不同 Assistant 用不同的 tools 子集，就按 name 过滤而不是全量注入。

**记忆策略按会话粒度注入**。`chatMemoryId` 用会话 ID，一个用户一个记忆窗口：

```java
interface TravelAssistant {
    String chat(@MemoryId String sessionId, @UserMessage String message);
}

// 框架层提供
ChatMemoryStore store = new PersistentChatMemoryStore(jdbcTemplate);
```

持久化到 JDBC 的表自己建（starter 有 DDL 脚本），重启不丢会话。

## 流式输出：SSE 接口三件套

LLM 应用的标配体验是打字机效果。Spring WebFlux + starter 的组合：

```java
@RestController
@RequestMapping("/api/assistant")
public class AssistantController {

    private final StreamingAssistant assistant;  // 接口方法返回 Flux<String>

    @GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<String> stream(@RequestParam String sessionId,
                               @RequestParam String message) {
        return assistant.chat(sessionId, message)
            .doOnNext(token -> log.debug("token: {}", token))
            .onErrorResume(e -> Flux.just("[系统] 生成中断：" + e.getMessage()));
    }
}
```

```java
interface StreamingAssistant {
    @SystemMessage("你是差旅助手")
    Flux<String> chat(@MemoryId String sessionId, @UserMessage String message);
}
```

接口返回 `Flux<String>`，框架自动走流式模型。三个工程细节：**必须配 error 兜底**——流式中途模型 API 断连，客户端只收到半个句子，没有 doOnErrorResume 的话错误直接冒泡成 500，前端那条 SSE 连接死得不明不白；**背压自然由 WebFlux 处理**，模型 token 生产远快于网络消费，Flux 的缓冲区要设上限，`onBackpressureBuffer(1000)` 防内存涨爆；**心跳帧**——模型思考超过 10 秒没有 token，SSE 连接可能被中间网关断掉，每隔几秒发个注释帧 `: ping\n\n` 保活。

## 连接池与限流：LLM API 不是无限水管

LangChain4j 底层用 OkHttp，连接池参数随模型 builder 走。更重要的应用层防护：**令牌桶限流**。模型 API 的速率限制是硬约束（TPM/RPM），Agent 循环调工具时并发几个请求就可能撞墙：

```java
@Bean
RateLimiter llmRateLimiter() {
    // 令牌桶：60 请求/分钟，应对 RPM 限制
    return RateLimiter.create(1.0);  // 每秒 1 个令牌
}

// 包装 assistant 调用
String chat(String sessionId, String msg) {
    rateLimiter.acquire();
    return inner.chat(sessionId, msg);
}
```

resilience4j 的 CircuitBreaker 也该套在模型调用上：模型 API 连续超时时熔断，直接返回降级话术，别让请求线程池全部堵死在等 OpenAI 上。

## 可观测：Actuator + Micrometer

```java
// 指标中间件思路：统计每次调用的 token 和延迟
@Component
public class ModelMetrics {
    private final Counter tokensCounter;
    private final Timer callTimer;

    public ModelMetrics(MeterRegistry registry) {
        tokensCounter = Counter.builder("llm.tokens").register(registry);
        callTimer = Timer.builder("llm.call.duration").register(registry);
    }
}
```

关键指标就四个：**调用量、P99 延迟、token 消耗（成本）、错误率**。这四个接进 Prometheus + Grafana，运营侧看成本曲线，运维侧看延迟毛刺。想深度追踪 prompt/响应内容，才有必要引入 LangSmith——生产上大部分场景指标就够，别一上来就全链路。

## 测试：接口 mock 是最大红利

Java 技术栈的最大优势在这里：**AI Services 是接口，测试直接 mock 实现**，不需要任何 fake LLM 基础设施。

```java
@SpringBootTest
class TravelAssistantTest {

    @MockitoBean
    private TravelAssistant travelAssistant;  // 或注入真实 Bean 后 stub 模型客户端

    @Test
    void shouldAskWeatherWhenMentioningRain() {
        when(travelAssistant.chat(eq("s1"), contains("伞")))
            .thenReturn("上海后天有雨，建议带伞");

        var resp = controller.stream("s1", "后天去上海要带伞吗").collectList().block();

        assertThat(resp).contains("带伞");
    }
}
```

需要验证真实 prompt 逻辑时，不 mock 接口而是 mock `ChatLanguageModel`——桩死它的返回，测"模型给了 X，编排层是否正确解析并调了工具"。上一批文章里讲的 mock 三层次，在 Java 栈同样适用。

## 部署注意

- **JVM 内存**：本地 embedding 模型 + embedding store 会实打实吃堆。PGVector 这类外部 store 比 `InMemoryEmbeddingStore` 更适合多实例部署——内存版在多副本下各自为政，新索引不能共享。
- **优雅停机**：`spring.lifecycle.timeout-per-shutdown-phase=30s`，WebFlux 的 SSE 长连接在停机时等 in-flight 请求排空。
- **配置分层**：API key 走环境变量 + Spring Cloud Config/Vault，别落在 application.yml 里进 git。

## 结语

Spring Boot 集成 LangChain4j 的工程清单列完了：starter 装配配置、Bean 化 AI Services、WebFlux 出流式接口、限流熔断层、Micrometer 指标、mock 测试。整套下来没有一行是"LLM 专属黑魔法"——全都长在 Spring 工程师的肌肉记忆里，这正是 Java 团队选它的理由。
