# map/ multimap

# map基本概念

- map中的所有元素都是pair
- pair中第一个元素为key(键值),起到索引作用,第二个元素为value(实值)
- 所有的元素都会根据元素键值自动排序

本质: 

- map/multimap属于关联式容器,底层结构是用二叉树实现
    
    

优点: 

- 可以根据key值快速找到value值
    
    

map和multimap区别

- map不允许容器中有重复key值元素
    
    multmap允许容器中有重复key值元素
    

# map构造和赋值

## 构造

- map<T1, T2> mp;   map默认构造函数
- map(const map& map);   拷贝构造函数

## 赋值

- map& operator = (const map& mp);  重载等号操作符

map中所有元素都是成对出现的,插入的时候要使用对组

```cpp
void printMap(map<int, int>& m) {
    for (map<int, int>::iterator it = m.begin(); it != m.end(); it++) {
        cout << "key = " << it->first << " value = " << (*it).second << endl; 
    }
}
int main() {
    map<int, int> m; 
    m.insert(pair<int, int>(1, 10)); 
    m.insert(pair<int, int>(2, 20)); 
    m.insert(pair<int, int>(3, 60)); 
    m.insert(pair<int, int>(4, 40)); 
    m.insert(pair<int, int>(5, 50)); 
    printMap(m); 
    return 0; 
}
```

# map大小和交换

统计map容器大小以及交换map容器

函数原型

- size();  返回容器中元素的数目
    
    empty(); 
    
    swap(); 
    

# map插入和删除

函数原型: 

- inset(elem);
- clear();
- erase(pos);      删除pos迭代器所指的元素,返回下一个元素的迭代器
- erase(beg, end);
- erase(key); 删除容器中值为key的元素

```cpp
int main() {

    map<int, int> m; 
    // 插入 
    // 第一种
    m.insert(pair<int, int>(1, 10)); 
    //printMap(m);  
    // 第二种
    m.insert(make_pair(2, 20)); 
    //printMap(m); 
    // 第三种 
    m.insert(map<int, int>::value_type(3, 30)); 
    //printMap(m);  
    // 第四种
    m[4] = 40; 
    //printMap(m);  

    // 删除 
    //m.erase(m.begin()); 
    //printMap(m);  
    // m.erase(3); 
    // printMap(m); 
    
    return 0; 
}

```

# map查找和统计

函数原型: 

- find();  查找key是否存在,若存在,返回该键的元素的迭代器; 若不存在,返回set_end();
- count();    统计key的元素个数  —- 在map中不允许插入重复的key元素, 对于map而言,count统计的结果只能是0和 1; multimap可能大于1

# map容器排序

map容器默认排序规则为按照key值进行从小到大排序

利用仿函数,可以改变排序规则

实现降序排列

```cpp
class MyCompare {
public : 
    bool operator() (int v1, int v2) {
        return v1 > v2; 
    }
}; 
int main() {
    map<int, int, MyCompare> m; 
    for (int i = 1; i < 5; i++) {
        m.insert(make_pair(i, i * 10)); 
    } 
    for (auto it = m.begin(); it != m.end(); it++) {
        cout << "key = " << it->first << " value = " << (*it).second << endl;  
    }
    return 0; 
}
```