# const修饰成员函数

# 常函数

成员函数后加const后我们称这个函数为常函数

常函数内不可以修改成员函数

成员属性声明时加关键字mutable后,在常函数中依然可以修改

在函数后面加上const之后,就不能修改属性了

 

```
class Person { 
public: 
    void showPerson() const {
        // m_A = 100;  // erroe 
    }
    int m_A; 
}; 
```

加上const之后,就不能修改m_A了 

在每一个函数内部,都默认含有一个this指针,this指针的本质是指针常量,指针的指向是不可以修改的 

相当于int* const m_A = 100;  

在特殊变量前面加上mutable,就可以在常函数中修改这个值了

```cpp
class Person { 
public: 
    void showPerson() const {
        // m_A = 100;  // erroe 
        m_B = 12; // 可以修改
    }
    int m_A; 
    mutable int m_B; // 特殊变量,及时在常函数中,也可以修改 
}; 
```

# 常对象

声明对象前加上const称该对象为常对象

常对象只能调用常函数

在对象前面加上cost之后,就变为常对象

```cpp
class Person { 
public: 
    void showPerson() const {
        // m_A = 100;  // erroe 
        this->m_B = 12; // 可以修改
    }
    int m_A = 0; 
    mutable int m_B = 0; // 特殊变量,及时在常函数中,也可以修改 
}; 

void test02() {
    const Person p;   // 常对象
    // p.m_A = 100;  // 不能修改
    p.m_B = 100;  // m_B是一个特殊值,即使在常对象下也可以修改 
    cout << p.m_A << endl; 
}
```

常对象必须在创建的时候进行初始化

## 常对象只能调用常函数

```cpp
class Person { 
public: 
    void showPerson() const {
        // m_A = 100;  // erroe 
        this->m_B = 12; // 可以修改
    } 
    void func() {}
    int m_A = 0; 
    mutable int m_B = 0; // 特殊变量,及时在常函数中,也可以修改 
}; 
void test03() {
    const Person p; 
    // p.func(); // 报错,常对象只能调用常函数
    p.showPerson(); 
}
```

常对象不可以调用普通函数,因为普通函数可以修改属性