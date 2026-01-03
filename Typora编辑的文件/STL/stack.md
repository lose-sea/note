# stack

# stack基本概念

概念: stack是一种先进后出(First in Last Out, FULO)的数据结构,它只有一个出口

栈中只有顶端元素才可以被外界使用,因此不允许有遍历行为 

栈中进入数据为 — 入栈  push

栈中弹出数据为 — 出栈 pop 

# 栈的常用接口

## 构造函数

- stack<T> stk;    stack采用模块类实现,stack对象的默认构造形式
- stack<T>(const stack& stk);      构造拷贝函数

## 赋值操作

- stack& operator = (const stack& stk) ;  重载等号操作符 重载等号运算符

## 数据存储

- push(elem);  向栈顶添加元素
- pop();    从栈顶移除第一个元素
- top();  返回栈顶元素

## 大小操作

- empty();   判断堆栈是否为空
- size();       返回栈的大小