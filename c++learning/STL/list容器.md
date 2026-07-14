# list容器

# 基本概念

STL中的链表是一个双向循环链表

由于链表的存储方式并不是连续的内存空间,因此链表list中的迭代器只支持前移和后移, 属于双向迭代器

list优点

- 采用动态存储分配,不会造成内存浪费和溢出
    
    链表执行插入和删除操作十分方便,修改指针即可,不需要移动大量元素
    

list缺点 

- 链表灵活,但是空间(指针域)和时间(遍历)额外耗费较大
    
    

List有一个重要的特性,操作和删除操作都不会造成原有的list迭代器的失效,这在vector是不成立的

# list构造函数

- ist<T> lst; list采用模板类实现,对象的默认构造方式
    
    list<T> (beg, end);   构造函数将[beg, end)区间的元素拷贝给本身 
    
    list(n, elem); 构造函数将n个elem拷贝给本身 
    
    list(const list& lst);   拷贝构造函数
    

# list赋值和交换

给list容器进行赋值,以及交换list容器

函数原型

- assign(beg, end);  将[beg, end)区间中的数据拷贝赋值给本身
    
    assign(n, elem);  将n个elem拷贝赋值给本身
    
    liat& operator = (const list& lst);  重载等号运算符
    
    swap(lst); 将lst与本身的元素互换
    

# list大小操作

- empty() // 判断容器是否为空
    
    size() // 返回容器中元素的个数
    
    resize() // 重新指定容器的长度为nun, 若容器变长,则以默认值填充新位置; 若容器变短,则末尾超出容器长度的元素被删除
    
    resize(num, elem);  // 重新指定容器的长度为nun, 若容器变长,则以elem充新位置; 若容器变短,则末尾超出容器长度的元素被删除
    

# list插入和删除

函数原型

- pop_back();
    
    push_front(); 
    
    pop_front(); 
    
    insert(pos, elem); 在pos位置插入elem月元素的拷贝,返回新数据的位置
    
    insert(pos,n, elem); 在pos位置插入n个elem数据,无返回值
    
    insert(pos, beg, end); 
    
    clear();  清空容器中的所有数据
    
    erase(beg; end);  删除[beg, end)区间的数据,返回下一个数据的位置
    
    erase(pos); 删除pos位置的数据,返回下一个数据的位置
    
    remove(elem); 删除容器中所有与elem值匹配的元素
    

# list数据存取

- front(); 返回第一个元素
    
    beck(); 返回最后一个元素
    

**不可以用[]的方式和at()的方式访问list容器中的元素** 

- 原因是list本质链表,不是连续线性空间,迭代器也不支持随机访问
    
    

# list反转和排序

将容器中的元素反转,以及将容器中的数据进行排序

函数原型

- reverse();  反转链表
    
    sort();   排序链表
    

```cpp
bool cmp(int v1, int v2) {
    return v1 > v2; 
} 
int main() {
    list<int> l1; 
    for (int i = 0; i < 5; i++) {
        l1.push_back(i); 
    }  
    printList(l1); // 0 1 2 3 4 
    l1.reverse(); 
    printList(l1);   // 4 3 2 1 0 
    l1.push_back(1); 
    printList(l1);  // 4 3 2 1 0 1  
    l1.sort(); 
    printList(l1); // 0 1 1 2 3 4  

    // 自定义排序
    l1.sort(cmp); 
    printList(l1); // 4 3 2 1 1 0 
    return 0; 
}
```