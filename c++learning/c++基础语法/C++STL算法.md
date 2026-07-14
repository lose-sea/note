# lower_bound 详解（C++）

`lower_bound` 是 C++ **STL 算法库** 中最常用的二分查找函数，**专门用于有序区间**，核心作用是：

> 在**已排序**的区间中，找到**第一个大于等于目标值**的元素的迭代器

1. **前提**：使用的区间**必须是升序排序**的（无序区间会出错）
2. **返回值**：指向**第一个 ≥ 目标值**的元素的迭代器
3. **时间复杂度**：\(O(\log n)\)（二分查找，效率远高于遍历）
4. **头文件**：`#include <algorithm>`





# set.contains() 

判断集合中是否包含指定元素, 

时间复杂度: **O(log n)**





#   `std::accumulate`

求和

```
#include <numeric>  // 必须包含这个头文件

vector<int> vec = {1, 2, 3, 4, 5};

// 基本用法
int sum = accumulate(vec.begin(), vec.end(), 0);

// 对于 long long 类型
vector<long long> vec2 = {1, 2, 3, 4, 5};
long long sum2 = accumulate(vec2.begin(), vec2.end(), 0LL);

// 对于 double 类型
vector<double> vec3 = {1.1, 2.2, 3.3};
double sum3 = accumulate(vec3.begin(), vec3.end(), 0.0);
```