# cin cout 和 scanf printf

当程序运行的时候,在控制台输入123的时候,这时的123是三个字符,123是一个字符序列,程序会根据代码中的数据类型,可能将123解析成整型,也可能将123解析成字符串

比如

```c
	int num = 123;
	cin >> num; //输入123，就被解析成整数

	string str;
	cin >> str; //输入123， 就被解析成字符串

```

# scanf / printf 和 cin / cout 的对比

scanf和printf是C语言中的标准输入输出函数,而 cin和cout是C++中的标准输入输出流对象,它们各自有优缺点,整体上来说,cin 和 cout 会更加方便,但是有时候我们也不得不使用scanf和printf

## 格式控制差异

- scanf 和 printf 不能自动识别输入数据的类型，需要手动指定格式字符串，容易出现格式错误。开发者需要确保格式字符串与变量类型匹配，否则会导致未定义行为。
- cin 和 cout 会根据变量类型自动处理输入输出，避免格式化铺借误。相对 scanf 和 printf 而且，C++ 的cin 和 cout 更加易用。
- scanf 和 printf: 格式化输出更精确直观，特别适合复杂格式的输入输出，比如：在要求指定格式输出的时候，printf 函数就比 cout 更加方便和灵活。(例如保留2位小数打印)

## 性能差异

结论: scanf 和 printf 通常比cin 和 cout 块

原因:

- cin 和 cout 由于要考虑兼容C语言的输入和输出,封装实现的更加复杂,通常比 scanf 和 printf 稍慢,但这种差异在大多数情况应用场景下可以忽略不计
- 但是在竞赛的题目中,尤其是当输入,输出数据量较大时,使用cin和cout完成输入和输出时,经常会出现Time Limit Exceeded的情况,而scanf和printf就不存在类似的问题

总结:

- 1.C++ 中为了支持混合使用 cin/cout 和 scanf/printf,C++ 标准库默认会将 cin、cout 等 C++ 流对象与 stdin、stdout 等 C 标准库的流对象同步在一起。这种同步操作意味着每次使用 cin 或 cout 时，都会自动刷新 C 标准库的缓冲区，以确保 C++ 和 C 的 I/O 是一致的。这就导致了性能的下降。
- 2.在默认情况下，cin 和 cout 之间存在一种绑定关系。这种绑定意味着，每当从 cin 读取数据时，任何之前通过 cout 输出的内容都会被强制刷新到屏幕上。这种绑定定也可能导致性能问题，特别是在需要频繁读取大量数据的情况下。

提升cin和cout效率的方法

```c
int main() {
    ios::sync_with_stdio(false); //取消给C语言输入输出缓冲区的同步
	cin.tie(0); 				// 取消了cin和cout的默认绑定关系
    .....
    return 0;
}

```