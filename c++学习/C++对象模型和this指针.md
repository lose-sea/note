# C++对象模型和this指针

## 只有非静态成员变量属于类的对象上

# 成员变量和成员函数分开存储

在C++中, 类内的成员变量和成员函数分开存储

只有非静态成员才属于类的对象上

```cpp
class Person {

}; 
void test01() {
    Person p; 
    cout << sizeof(p) << endl; 
}
int main() {
    test01(); 
    return 0; 
}
```

空对象占用内存空间为:  1; 

C++编译器会给每个空对象也分配一个字节空间,是为了区分空对象占内存的位置

每个空对象也应该有一个独一无二的内存地址

```cpp
class Person {
    int m_a;  // 非静态的成员变量
}; 
void test01() {
    Person p; 
    cout << sizeof(p) << endl;  // 4
}
int main() {
    test01(); 
    return 0; 
}
```

非静态成员变量,属于类的对象上

静态成员变量,不属于类的对象上

```cpp
class Person {
    int m_a;  // 非静态的成员变量 
    static int m_b; 
}; 
void test01() {
    Person p; 
    cout << sizeof(p) << endl;   // 4
}
int main() {
    test01(); 
    return 0; 
} 
```

非静态成员函数,不属于类的对象上

```cpp
class Person {
    int m_a;  // 非静态的成员变量 
    static int m_b;  // 静态的成员变量 
    void func(); 
}; 
void test01() {
    Person p; 
    cout << sizeof(p) << endl;   // 4
}
int main() {
    test01(); 
    return 0; 
} 
```

静态成员函数,不属于类的对象上

```cpp
class Person {
    int m_a;  // 非静态的成员变量 
    static int m_b;  // 静态的成员变量 
    void func(); // 非静态成员函数,不属于类的对象上 
    static void fund(); // 静态成员函数,不属于类的对象上 
}; 
void test01() {
    Person p; 
    cout << sizeof(p) << endl;   // 4
}
```

# this指针概念

每一个非静态成员函数只会诞生一份函数实例,也就是说多个同类型的对象共用一块代码

那么,这一块代码是如何区分哪个对象调用自己的呢? 

C++通过提供特殊的对象指针,this指针,解决上述问题.this指针指向被调用的成员函数所属的对象 

- this指针是隐含每一个非静态成员函数内的一种指针
- this指针不需要定义,直接使用即可

this指针的用途: 

- 当形参和成员函数同名时,可用this指针区分
- 在类的非静态成员函数中返回对象本身,可使用return *this;

名称冲突

```cpp
class Person {
public : 
    Person(int age) {
        age = age; // 名称冲突
    } 
    int age; 
}; 
void test01() {
    Person p(18); 
    cout << p.age << endl;  // 0
} 
```

this指针所指向的是被调用的成员函数所指属的对象

```cpp
class Person {
public : 
    Person(int age) {
        this->age = age; 
    } 
    int age; 
}; 
void test01() {
    Person p(18); 
    cout << p.age << endl;  // 18
} 
```

```cpp
class Person { 
public :  
    Person(int age) { 
        this->age = age; 
    } 
    void PersonAddAge(Person& p) {
        this->age += p.age; 
    }
    int age; 
}; 
void test02() {
    Person p1(10); 
    Person p2(20); 
    p2.PersonAddAge(p1); 
    cout << "p2的年龄为" << p2.age << endl;  // 30
}

```

利用this返回对象本身

this指向p2的指针,而*this指向的就是p2这个对象本身

```cpp
class Person { 
public :  
    Person(int age) { 
        this->age = age; 
    } 
    Person& PersonAddAge(Person& p) {
        this->age += p.age; 
        return *this; 
    } 
    int age; 
}; 
void test02() {
    Person p1(10); 
    Person p2(20); 
    p2.PersonAddAge(p1).PersonAddAge(p1);  
    cout << "p2的年龄为" << p2.age << endl;  // 40 
} 
```

引用的本质是指针常量,指针的指向不可以改变,指向的值可以改变