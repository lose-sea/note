# vector

# vector 基本概念

## 功能

vector数据结构和数组非常相似，也称为**单端数组**

## 与普通数组的区别

数组是静态空间,而vector可以动态扩展

## 动态扩展

并不是在原空间之后续接新空间,而是找更大的内存空间,然后将原数据拷贝到新空间,释放原空间

# vector 构造函数

创建vector容器

函数原型

> vector v;vector(v.begin(), v.end()); // 用区间的方式进行构造
vector(n, elem);vector(const vector &vec); 拷贝构造
> 

```cpp
#include<iostream>
#include<vector>
using namespace std;

void printVector(vector<int>&v) {
    for (vector<int>::iterator it = v.begin(); it != v.end(); it++) {
        cout << *it << " ";
    }
    cout << endl;
}

int main() {
    // vector构造函数
    // vector<T> v; 
    vector<int> v1;  // 默认构造,无参构造
    for (int i = 0; i < 10; i++) {
        v1.push_back(i + 10);
    }
    printVector(v1); // 10 11 12 13 14 15 16 17 18 19

    // vector(v.begin(), v.end());  // 用区间的方式进行构造
    vector<int>v2(v1.begin(), v1.end());
    printVector(v2); // 10 11 12 13 14 15 16 17 18 19

    // vector(n, elem);
    vector<int>v3(10, 6);
    printVector(v3); // 6 6 6 6 6 6 6 6 6 6

    // vector(const vector &vec);  拷贝构造
    vector<int>v4(v3);
    printVector(v4); // 6 6 6 6 6 6 6 6 6 6

    return 0;
}
```

# vector赋值操作

给vector容器进行赋值

函数原型

> vector& operator = (const vector &vec); // 重载等号操作符assign(beg, end); // 将[beg, end)区间中的数据拷贝给本身assign(n, elem);
> 

```cpp
#include<iostream>
#include<vector>
using namespace std;

void printVector(vector<int>& v) {
    for (vector<int>::iterator it = v.begin(); it != v.end(); it++) {
        cout << *it << " ";
    }
}

int main() {
    vector<int> v;
    for (int i = 0; i < 10; i++) {
        v.push_back(i);
    }  // 0 1 2 3 4 5 6 7 8 9

    // vector& operator = (const vector &vec); // 重载等号操作符
    vector<int> v1 = v;
    printVector(v1); // 0 1 2 3 4 5 6 7 8 9
    cout << endl;

    // assign(beg, end); // 将[beg, end)区间中的数据拷贝给本身
    vector<int> v2;
    v2.assign(v.begin(), v.end());
    printVector(v2);  // 0 1 2 3 4 5 6 7 8 9
    cout << endl;

    // assign(n, elem);
    vector<int> v3;
    v3.assign(10, 4);
    printVector(v3);  // 4 4 4 4 4 4 4 4 4 4

    return 0;
}
```

# vector容量和大小

对vector容器的容量和大小操作

函数原型

> enpty() // 判断容器是否为空
> 
> 
> capacity(); // 容器的容量
> 
> size(); // 返回容器中元素的个数
> 
> resize(int num); // 重新指定容器的长度为num,若容器变长,则以默认值填充新位置.若容器变短,则末尾超出容器长度的元素被删除
> 
> resize(int num, elem); // 重新指定容器的长度为num,若容器变长,则以elem填充新位置.若容器变短,则末尾超出容器长度的元素被删除
> 

```cpp
    vector<int> v;
// v.resize(10);
// for (size_t i = 0; i < v.capacity(); i++) {
//     cout << v[i] << " ";
// }  // 0 0 0 0 0 0 0 0 0 0

v.resize(10, 2);
for (size_t i = 0; i < v.capacity(); i++) {
    cout << v[i] << " ";
}  // 2 2 2 2 2 2 2 2 2 2
```

# vector插入和删除

对vector容器进行插入, 删除操作

`advance(it, n);  // 将迭代器 it 向前移动 n 个位置`

函数原型

> push_back(elem); // 尾部插入元素
> 
> 
> pop_back(); // 删除最后一个元素
> 
> insert(const_inerator pos, ele); // 迭代器指向位置pos插入元素ele
> 
> insert(const_iterator pos, int count, ele); // 迭代器指向位置pos插入count个元素ele
> 
> erase(const_iterator pos); // 删除迭代器指向的元素
> 
> erase(const_inerator start, const_iterator end); // 删除迭代器从strat到end之间的元素
> 
> clear(); // 删除容器中的所有元素
> 

```cpp
#include<iostream>
#include<vector>
using namespace std;

void printVector(vector<int>& v) {
    for (vector<int>::iterator it = v.begin(); it != v.end(); it++) {
        cout << *it << " ";
    }
    cout << endl;
}

int main() {
    vector<int> v;
    for (int i = 0; i < 10; i++) {
        v.push_back(i);
    }
    // printVector(v);   // 0 1 2 3 4 5 6 7 8 9

    //v.insert(v.begin() + 2, 2, 100);
    // printVector(v);  // 0 1 100 100 2 3 4 5 6 7 8 9

    // v.erase(v.begin() + 1, v.begin() + 4);
    // printVector(v);  // 0 4 5 6 7 8 9

    v.clear(); // 清空
    printVector(v);  // 无输出（空vector）
    
    return 0;
}
```

# vector数据存取

对vector中的数据的存取操作

函数原型

> at(int idx); // 返回索引idx所指的元素
> 
> 
> operator[]; // 返回索引idx所指的元素
> 
> front(); // 返回容器中第一个数据元素
> 
> back(); // 返回容器中最后一个数据元素
> 

```cpp
#include<iostream>
#include<vector>
using namespace std;

int main() {
    vector<int> v;
    for (int i = 0; i < 10; i++) {
        v.push_back(i);
    }
    
    cout << v.at(4) << endl;    // 4
    cout << v[4] << endl;       // 4
    cout << v.front() << endl;  // 0
    cout << v.back() << endl;   // 9
    
    return 0;
}
```

# 互换容器

实现两个容器内元素进行互换

函数原型

> swap(vec); 将vec与本身的元素进行互换
> 

```cpp
#include<iostream>
#include<vector>
using namespace std;

void printVector(vector<int>& v) {
    for (vector<int>::iterator it = v.begin(); it != v.end(); it++) {
        cout << *it << " ";
    }
}

int main() {
    // swap(vec); 将vec与本身的元素进行互换
    vector<int> v1(10, 10);
    vector<int> v2;
    for (int i = 0; i < 10; i++) {
        v2.push_back(i);
    }
    
    printVector(v1); // 10 10 10 10 10 10 10 10 10 10
    cout << endl;
    printVector(v2);  // 0 1 2 3 4 5 6 7 8 9
    cout << endl;
    
    cout << "互换后" << endl;
    v1.swap(v2);
    
    printVector(v1); // 0 1 2 3 4 5 6 7 8 9
    cout << endl;
    printVector(v2);  // 10 10 10 10 10 10 10 10 10 10
    
    return 0;
}
```

## swap() 的实际用途

巧用swap收缩内存

```cpp
int main() {
    vector<int> v;
    for (int i = 0; i < 100000; i++) {
        v.push_back(i);
    }
    cout << v.capacity() << endl; // 131072
    cout << v.size() << endl;  // 100000
    v.resize(3);
    cout << v.capacity() << endl;  // 131072  // resize() 并没有使容量改变
    cout << v.size() << endl;  // 3
    return 0;
}
```

使用swap()

```cpp
int main() {
    // 使用swap收缩内存空间    
    vector<int>(v).swap(v);
    cout << v.size() << endl;  // 3
    cout << v.capacity() << endl;  // 3
    return 0;
}
```

> vector(v);匿名对象,用 v 拷贝构造, 大小是3, 容量也是3
> 
> 
> `.swap(v)`然后和v进行交换,v的大小和内存就也变为3了
> 
> 匿名对象的特点:当前行执行完之后,系统会回收匿名对象的空间
> 

# vector预留空间

减少vector在动态扩展时的扩展次数

函数原型

- reseve(int len); 容器预留len个元素长度,**预留位置不初始化,元素不可访问**

**resize() 和 reserve() 都可以扩展内存,他们有什么区别**

> reserve(n)： 只为容器预留至少能够容纳n个元素的内存，避免后续插入时频繁扩容但容器内实际元素个数不变(size()仍然为原来的值)
> 
> 
> reserve(n): 强制将容器元素个数调整为n – 不足则补默认构造的元素,多余则删除尾部元素,size() 和 capacity() 可能同时变化
> 
> **`reserve(n)` 只在 `n > current_capacity` 时有效**
> 
> - 如果 `n <= capacity()`，**什么都不做**
> - 如果 `n > capacity()`，**扩容到至少 n**

vector容器扩展内存是重新找一块更大的地址,将原来的数据拷贝过去

```cpp
int main() {
    vector<int> v;
    int num = 0;  // 统计开辟内存的数据    
    int* p = NULL;
    for (int i = 0; i < 100000; i++) {
        v.push_back(i);
        if (p != &v[0]) {
            p = &v[0];
            num++;
        }
    }
    cout << num << endl;  // 18 --> 开辟了18次内存    
    return 0 ;
}
```

用reserce()可以减少扩展内存的次数

```cpp
int main() {
    vector<int> v;
    int num = 0;  // 统计开辟内存的数据    // 用reserve()预留空间    
    v.reserve(100000);
    int* p = NULL;
    for (int i = 0; i < 100000; i++) {
        v.push_back(i);
        if (p != &v[0]) {
            p = &v[0];
            num++;
        }
    }
    cout << num << endl;  // 1 --> 只开辟了一次内存    
    return 0 ;
}
```