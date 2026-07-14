# queue容器

# queue基本概念

Queue是一种先进先出(First In First Out, FIFO)的数据结构, 它有两个出口

- 队列容器允许从一端新增元素,从另一端移除元素,
    
    队列中只有队头和队尾可以被外界使用,因此队列不允许有遍历行为. 
    
    队列中进数据称为 — 入队  push 
    
    队列中出数据称为 — 出队  pop  
    

# queue常用借口

## 构造函数

- queue<T> que;      queue采用模块类实现,queue对象的默认构造形式
- queue(const queue& que); 拷贝构造函数

# 赋值操作

- queue& operator = (const queue& que);   重载等号运算符

# 数据存取

- push(elem); 往队尾添加元素
- pop();   从队头移除第一个元素
- back();   返回最后一个元素
- first();    返回第一个元素

## 大小操作

empty(); 判断栈是否为空

size();   返回栈的大小