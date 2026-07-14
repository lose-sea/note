# nullptr和NULL的区别

在 C++ 中，`nullptr`和`NULL`都是用来表示 “空指针” 的，但二者**本质、类型、适用场景**有明显区别：

### **1. 本质与类型不同**

- **`NULL`**：是 C 语言继承来的宏，在 C++ 中通常被定义为 `0`（或 `(void*)0`，但不同编译器实现可能有差异）。它的**类型是`int`**（不是指针类型）。
- **`nullptr`**：是 C++11 新增的**关键字**，专门表示 “空指针常量”。它的**类型是`std::nullptr_t`**（是一种独立的指针类型，可以隐式转换为任意指针类型）。

### **2. 适用场景的区别**

由于类型不同，二者在**函数重载、模板匹配**等场景下表现完全不同：

### **（1）函数重载时的差异**

**cpp**

```cpp
#include <iostream>
using namespace std;

void func(int x) {
    cout << "调用int版本" << endl;
}
void func(char* p) {
    cout << "调用指针版本" << endl;
}

int main() {
    func(NULL);    // 调用func(int)（因为NULL是int类型）
    func(nullptr); // 调用func(char*)（因为nullptr是指针类型）
    return 0;
}
```

- 传`NULL`会匹配`int`版本（不符合 “空指针” 的预期）；
- 传`nullptr`会正确匹配指针版本。

### **（2）模板匹配时的差异**

`NULL`的`int`类型会导致模板推导错误，而`nullptr`可以正确推导为指针类型：

**cpp**

`template <typename T>
void func(T* p) { /* ... */ }

int main() {
    func(NULL);    // 错误：NULL是int，无法推导为T*
    func(nullptr); // 正确：nullptr隐式转为T*
    return 0;
}`

### **3. 总结：推荐用`nullptr`**

在 C++ 中，**`nullptr`是 “空指针” 的标准、安全写法**，可以避免`NULL`带来的类型混淆问题；而`NULL`更多是为了兼容 C 语言的历史遗留用法。