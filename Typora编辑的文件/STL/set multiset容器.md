# set/multiset容器

## 特点：

所有的元素都会在插入的时候自动排序

## 本质：

set / multiset属于关联式容器，底层结构是用二叉树

## set与multiset区别

- set不允许有重复的元素
- multiset允许容器中有重复的元素

# set构造和赋值

## 构造

- set<T> st;  默认构造函数
- set(const set& st);   拷贝构造函数

## 赋值

- set<T> operator = (const set& st);   重载等号运算符

## 插入数据

只有insert方式

```cpp
    set<int> st; 
    st.insert(10); 
    st.insert(40); 
    st.insert(30); 
    st.insert(80); 
    st.insert(20); 
```

遍历容器

set容器特点:

- 所有元素插入的时候自动被排序
    
    set容器不允许插入重复值
    

```cpp
int main() {
    set<int> st; 
    st.insert(10); 
    st.insert(40); 
    st.insert(30); 
    st.insert(80); 
    st.insert(20); 
    printSet(st);   // 10 20 30 40 80
    return 0; 
}
```

# set容器大小和交换

- 函数原型
    
    size();        返回容器中元素的数目
    
    empty();     判断容器是否为空
    
    swap();     交换两个集合容器
    

# set插入和删除

函数原型

- insert(elem);
- clear();
- erase(pos); 删除pos迭代器所指的元素,返回下一个元素的迭代器
- erase(beg, end);   删除区间[beg, end)的所有元素,返回下一个元素的迭代器
- erase(elem);   // 删除容器中指为elem的元素

# set查找和统计

函数原型

- find(key);   查找key是否存在,返回指向该元素的迭代器,若不存在,返回set.end();
- count(key);   统计key的元素的个数     对于set而言,只有0 和 1;

```cpp
int main() {

    // find(key);   查找key是否存在,返回指向该元素的迭代器,若不存在,返回set.end(); 
    // count(key);   统计key的元素的个数
    set<int> s; 
    for (int i = 0; i < 10; i++) {
        s.insert(i); 
    }  
    if (s.find(55) == s.end()) {
        cout << "不存在" << endl; 
    } else {
        cout << "存在" << endl; 
    }    // 不存在
    return 0; 
}
```

# set和multiset区别

- set不可以插入重复数据,而multiset可以
    
    set插入数据的同时会返回插入数据,表示是否成功
    
    multset不会检查数据,因此可以插入重复数据
    

# pair对组创建

## 功能描述

成对出现的数据,利用队组可以返回两个数据

## 两种创建方式

- pair<type, type> p (value1, value2);  
pair<type, type> p = make_pair(value1, value2);
    
    

```cpp
int main() {
    // 第一种方式
    pair<string, int>p1("Tom", 20); 
    cout << "姓名: " << p1.first << " 年龄 " << p1.second << endl; // 姓名: Tom 年龄 20 
    // 第二种方式

    pair<string, int> p2 = make_pair("John", 45); 
    cout << "姓名: " << p2.first << " 年龄 " << p2.second << endl;
    return 0; 
}
```

# set容器排序

set默认排序方式是升序排序

利用仿函数,可以改变排序规则

```cpp
class MyComper { 
public:
    bool operator()(int v1, int v2) {
        return v1 > v2; 
    }
}; 
int main() {
    set<int, MyComper> s1; 
    s1.insert(10); 
    s1.insert(30); 
    s1.insert(40); 
    s1.insert(20); 
    s1.insert(50); 
    cout << "降序" << endl;  
    for (auto it = s1.begin(); it != s1.end(); it++) {
        cout << *it << " "; 
    }  // 50 40 30 20 10
    return 0; 
}
```

对于自定义数据类型,都需要指定排序规则