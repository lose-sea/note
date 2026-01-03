# STL初识

# STL的诞生

- 长久以来，软件界一直希望建立一种可重复利用的东西
- C++的面向对象和泛型编程思想，目的就是复用性的提升
- 大多情况下，数据结构和算法都未能又一套标准，导致被迫从事大量重复工作
- 为了建立数据结构和算法的一套标准，诞生了STL

# STL基本概念

- STL（Standard Template Library)标准模板库
- STL从广义上分为: 容器(container) 算法(algorithm) 迭代器(iterator)
- 容器和算法之间通过迭代器进行无缝连接
- STL几乎所有的代码采用了模板类或者模板函数

# STL六大组件

STL大体分为六大组件,分别是: 容器,算法,迭代器,仿函数,适配器(配接器), 空间配置器

- 容器 ; 各种数据结构,如vector , list , deque, set, map等,来存放数据
- 算法: 各种常用的算法,如sort, find, copy, for_each等
- 迭代器: 扮演了容器与算法之间的胶合剂
- 仿函数: 行为类似函数,可作为算法的某种策略
- 适配器: 一种采用修饰容器或者迭代器接口的东西
- 空间配置器: 负责空间的配置与管理

# STL中容器,算法,迭代器

## 容器:置物之所也

STL容器就是将运用最广泛的一些数据结构实现出来

常用的数据结构: 数组,链表,树,栈,队列,集合,映射表等

这些容器分为**序列式容器**和**关联式容器**两种:

- 序列式容器: 强调值的排序,序列式容器中的每一个元素均有固定的位置
- 关联式容器:二叉树结构,各元素之间没有严格的物理上的顺序关系

## 算法:问题之解法也

有限的步骤,解决逻辑或者数学上的问题,这一门学科我们叫做算法

算法分为**质变算法**和**非质变算法**

质变算法: 是指运算过程中会改变更改区间内元素的内容, 例如拷贝,替换,删除等

非质变算法: 是值运算过程中不会更改区间内的元素内容,例如查找,计数, 遍历,寻找极值等

## 迭代器 容器和算法之间的粘合剂

提供一种方法,使之能够依序寻访某个容器所含的各个元素,而又无需暴露该容器的内部表示方式

每个容器都有自己专属的迭代器

迭代器使用非常类似于指针

迭代器种类

| 种类 | 功能 | 支持运算 |
| --- | --- | --- |
| 输入迭代器 | 对数据的只读访问 | 只读,支持++,==,!= |
| 输出迭代器 | 对数据的只写访问 | 只写,支持++ |
| 前向迭代器 | 读写操作,并能向前推进迭代器 | 读写,支持++,==,!= |
| 双向迭代器 | 读写操作,并能向前和向后操作 | 读写,支持++,– |
| 随机访问迭代器 | 读写操作,可以以跳跃的方式访问任意数据,功能最强的迭代器 | 读写,支持++,–,[n],-n,<,<=,>,>= |

常用的容器中迭代器种类为双向迭代器和随机访问迭代器

# vestor存放内置数据类型

容器： vector

算法： for_ench

迭代器： vector::iterator

创建一个vector容器 (需包含头文件)

```cpp
    vector<int> v;
```

向容器中插入数据 尾插

```cpp
    v.push_back(10);
    v.push_back(20);
    v.push_back(30);
```

通过迭代器访问容器中的数据

```cpp
vector<int>::iterator itBegin = v.begin(); // 起始迭代器vector<int>::iterator itEnd = v.end();      // 结束迭代器，指向容器中最后一个元素的下一个位置
```

遍历容器

第一种遍历方式 while 循环

```cpp
//第一种遍历方式    while (itBegin != itEnd) {        cout << *itBegin << endl;
        itBegin++;
    }
```

第二种遍历方式 fo r循环

```cpp
//第二种遍历方式    for (vector<int>::iterator it = v.begin(); it < v.end(); it++) {        cout << *it << endl;
    }
```

第三种遍历方式 利用STL提供的遍历算法 （需要包含头文件 –>标准算法的头文件 ）

```cpp
void myprint(int val) {    cout << val << endl;
}
void test01()  {    // 创建了一个vector容器，数组    vector<int> v;
    // 向容器中插入数据  尾插    v.push_back(10);
    v.push_back(20);
    v.push_back(30);
    for_each(v.begin(), v.end(), myprint);
}
```

`UnaryFunction for_each( InputIt first, InputIt last, UnaryFunction f );`

> UnaryFunction 指的是一元函数，即接受一个参数并执行某些操作的函数对象
> 
> 
> `first` - 起始迭代器
> 
> `last` - 结束迭代器
> 
> `f` - 函数对象
> 
> - **类型**：一元函数 (UnaryFunction)
> - **作用**：对每个元素执行的操作
> - **可以是**：普通函数、函数指针、lambda表达式、函数对象

# vector 存放自定义数据类型

创建类型

```cpp
class Person {public :    Person(string name, int age) {        this->name = name;
        this->age = age;
    }    string name;
    int age;
};
```

方法一

```cpp
void test01() {    vector<Person> v;
    Person p1("aaa", 10);
    Person p2("bbb", 20);    Person p3("ccc", 30);    Person p4("ddd", 40);
    // 向容器中添加数据    v.push_back(p1);
    v.push_back(p2);    v.push_back(p4);    v.push_back(p4);    for (vector<Person>::iterator it = v.begin(); it != v.end(); it++) {        cout << (*it).name << endl;
    }}
```

方法二 通过指针进行操作

```cpp
void test02() {    vector<Person*> v;
    Person p1("aaa", 10);
    Person p2("bbb", 20);    Person p3("ccc", 30);    Person p4("ddd", 40);
    // 向容器中添加数据    v.push_back(&p1);
    v.push_back(&p2);    v.push_back(&p4);    v.push_back(&p4);    // 遍历容器    for (vector<Person*>::iterator it = v.begin(); it != v.end(); it++) {        cout << (*it)->name << endl;
    }}
```

# 容器嵌套容器

将小容器插入到大容器中

创建大容器

```cpp
vector<vector<int>> v;
```

创建嵌套容器

```cpp
    vector<int> v1;
    vector<int> v2;    vector<int> v3;    vector<int> v4;
```

向小容器中添加数据

```cpp
    for (int i = 0; i < 4; i++) {        v1.push_back(i + 1);
        v2.push_back(i + 1);        v3.push_back(i + 1);        v4.push_back(i + 1);    }
```

将小容器插入到大容器中

```cpp
    v.push_back(v1);
    v.push_back(v2);    v.push_back(v3);    v.push_back(v4);
```

和打印二维数组一样,通过循环嵌套的方式打印嵌套容器

```cpp
    for (vector<vector<int>>::iterator it1 = v.begin(); it1 != v.end(); it1++) {        for (vector<int>::iterator it2 = (*it1).begin(); it2 != (*it1).end(); it2++) {            cout << *it2 << " ";
        }
        cout << endl;    }
```