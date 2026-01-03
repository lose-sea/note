# STL学习顺序

## 🗂️ **一、容器 (Containers) 详解**

### 1. vector（动态数组）

### 基本操作

cpp

```cpp
#include <vector>#include <iostream>using namespace std;

int main() {
    // 构造函数
    vector<int> v1;                    // 空vector
    vector<int> v2(5, 10);             // 5个10: {10,10,10,10,10}
    vector<int> v3 = {1, 2, 3, 4, 5};  // 列表初始化
    vector<int> v4(v3.begin(), v3.end()); // 拷贝v3

    // 元素访问
    cout << v3[0] << endl;        // 1 (不检查边界)
    cout << v3.at(1) << endl;     // 2 (检查边界，越界抛出异常)
    cout << v3.front() << endl;   // 1 (第一个元素)
    cout << v3.back() << endl;    // 5 (最后一个元素)

    // 迭代器访问
    auto it = v3.begin();
    cout << *it << endl;          // 1

    // 容量操作
    cout << "大小: " << v3.size() << endl;         // 5
    cout << "容量: " << v3.capacity() << endl;     // 可能大于5
    cout << "是否为空: " << v3.empty() << endl;    // 0 (false)

    v3.reserve(20);  // 预留容量为20
    v3.shrink_to_fit();  // 收缩容量到匹配大小

    return 0;
}
```

### 插入删除操作

cpp

```cpp
vector<int> vec = {1, 2, 3};

// 尾部操作
vec.push_back(4);           // {1,2,3,4}
vec.emplace_back(5);        // {1,2,3,4,5} - 更高效
vec.pop_back();             // {1,2,3,4} - 删除尾部

// 指定位置操作
vec.insert(vec.begin() + 1, 9);       // {1,9,2,3,4}
vec.insert(vec.begin() + 2, 2, 8);    // {1,9,8,8,2,3,4} - 插入2个8

vec.erase(vec.begin() + 1);           // {1,8,8,2,3,4} - 删除位置1
vec.erase(vec.begin() + 1, vec.begin() + 3); // {1,2,3,4} - 删除[1,3)

vec.clear();  // 清空所有元素
```

### 性能特点

- **随机访问**：O(1)
- **尾部插入/删除**：O(1) 平均
- **中间插入/删除**：O(n)
- **内存**：连续存储，缓存友好

### 2. deque（双端队列）

### 基本操作

cpp

```cpp
#include <deque>

deque<int> dq = {2, 3, 4};

// 双端插入
dq.push_front(1);    // {1,2,3,4}
dq.push_back(5);     // {1,2,3,4,5}

// 双端删除
dq.pop_front();      // {2,3,4,5}
dq.pop_back();       // {2,3,4}

// 随机访问
cout << dq[0] << endl;    // 2
cout << dq.at(1) << endl; // 3

// 容量操作
cout << "大小: " << dq.size() << endl;
dq.shrink_to_fit();  // 请求减少内存使用
```

### 性能特点

- **头尾插入/删除**：O(1)
- **随机访问**：O(1)
- **中间插入/删除**：O(n)
- **内存**：分段连续存储

### 3. list（双向链表）

### 基本操作

cpp

```cpp
#include <list>

list<int> lst = {1, 3, 5};

// 插入操作
lst.push_front(0);        // {0,1,3,5}
lst.push_back(7);         // {0,1,3,5,7}

auto it = lst.begin();
advance(it, 2);           // 移动到位置2
lst.insert(it, 2);        // {0,1,2,3,5,7}

// 删除操作
lst.pop_front();          // {1,2,3,5,7}
lst.pop_back();           // {1,2,3,5}

it = lst.begin();
advance(it, 1);
lst.erase(it);            // {1,3,5}

// 特殊操作
lst.sort();               // 排序
lst.unique();             // 去重（需要先排序）
lst.reverse();            // 反转
lst.remove(3);            // 删除所有3

// 合并链表
list<int> lst2 = {4, 6, 8};
lst.merge(lst2);          // 合并两个有序链表
```

### 性能特点

- **任意位置插入/删除**：O(1)（已知位置）
- **随机访问**：O(n)
- **排序**：成员函数sort()比算法sort()更高效

### 4. set/multiset（集合）

### set（唯一元素）

cpp

```cpp
#include <set>

set<int> s = {3, 1, 4, 1, 5};  // {1,3,4,5} - 自动排序去重

// 插入操作

auto result = s.insert(2);      // 返回pair<iterator, bool>
if (result.second) {
    cout << "插入成功" << endl;
}

s.insert({6, 7, 8});           // 批量插入

// 查找操作
auto it = s.find(3);           // 查找元素3
if (it != s.end()) {
    cout << "找到: " << *it << endl;
}

cout << s.count(4) << endl;    // 1 (存在)
cout << s.count(9) << endl;    // 0 (不存在)

// 范围查找
auto lower = s.lower_bound(3);  // 第一个>=3的元素
auto upper = s.upper_bound(5);  // 第一个>5的元素
for (auto it = lower; it != upper; it++) {
    cout << *it << " ";         // 3,4,5
}

// 删除操作
s.erase(4);                    // 删除元素4
s.erase(s.find(3));            // 删除迭代器指向的元素
```

### multiset（允许重复）

cpp

```cpp
multiset<int> ms = {1, 2, 2, 3, 3, 3};

cout << ms.count(2) << endl;   // 2 (统计个数)

auto range = ms.equal_range(3); // 所有等于3的元素范围
for (auto it = range.first; it != range.second; it++) {
    cout << *it << " ";         // 3,3,3
}
```

### 性能特点

- **插入/删除/查找**：O(log n)
- **自动排序**
- **基于红黑树实现**

### 5. map/multimap（映射）

### map（键值对）

cpp

```cpp
#include <map>

map<string, int> scores = {{"Alice", 95}, {"Bob", 85}};

// 插入操作
scores.insert({"Charlie", 90});
scores.emplace("David", 88);    // 直接构造
scores["Eve"] = 92;             // 使用下标操作符

// 访问操作
cout << scores["Alice"] << endl;        // 95
cout << scores.at("Bob") << endl;       // 85

auto it = scores.find("Charlie");
if (it != scores.end()) {
    cout << it->first << ": " << it->second << endl;  // Charlie: 90
}

// 遍历操作
for (const auto& pair : scores) {
    cout << pair.first << ": " << pair.second << endl;
}

// C++17 结构化绑定
for (const auto& [name, score] : scores) {
    cout << name << ": " << score << endl;
}

// 删除操作
scores.erase("Alice");
scores.erase(scores.find("Bob"));
```

### multimap（允许重复键）

cpp

```cpp
multimap<string, int> mm;

mm.insert({"Alice", 95});
mm.insert({"Alice", 88});  // 允许重复键

auto range = mm.equal_range("Alice");
for (auto it = range.first; it != range.second; it++) {
    cout << it->first << ": " << it->second << endl;
}
```

## equal_range 详解

cpp

```
pair<iterator, iterator> equal_range(const Key& key);
```

返回一个包含两个迭代器的 `pair`：

- `first`：指向第一个等于 `key` 的元素
- `second`：指向最后一个等于 `key` 的元素的下一个位置

## 基本用法（您的示例）

cpp

```cpp
#include <iostream>#include <map>using namespace std;

int main() {
    multimap<string, int> mm;

    mm.insert({"Alice", 95});
    mm.insert({"Alice", 88});
    mm.insert({"Alice", 92});
    mm.insert({"Bob", 85});
    mm.insert({"Charlie", 90});

    // 查找所有 "Alice" 的记录
    auto range = mm.equal_range("Alice");

    cout << "Alice的所有成绩:" << endl;
    for (auto it = range.first; it != range.second; it++) {
        cout << it->first << ": " << it->second << endl;
    }

    return 0;
}
```

**输出：**

text

```
Alice的所有成绩:
Alice: 95
Alice: 88
Alice: 92
```

### 6. unordered_set/unordered_map（哈希容器）

### unordered_map

cpp

```cpp
#include <unordered_map>

unordered_map<string, int> hash_map = {{"Apple", 1}, {"Banana", 2}};

// 插入访问（与map类似）
hash_map["Cherry"] = 3;
cout << hash_map["Apple"] << endl;

// 桶操作
cout << "桶数量: " << hash_map.bucket_count() << endl;
cout << "负载因子: " << hash_map.load_factor() << endl;

// 调整性能
hash_map.reserve(100);  // 预留空间
hash_map.rehash(50);    // 重新哈希

// 遍历桶
for (size_t i = 0; i < hash_map.bucket_count(); i++) {
    cout << "桶 " << i << " 有 " << hash_map.bucket_size(i) << " 个元素" << endl;
}
```

### 性能特点

- **平均插入/删除/查找**：O(1)
- **最坏情况**：O(n)
- **无序存储**
- **基于哈希表实现**