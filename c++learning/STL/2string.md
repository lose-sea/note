# 2string

# string 基本基本概念

**本质**

string 是C++分格的字符串,而string本质上是一个类

string和C++区别

- char* 是一个指针
- string是一个类,类内部封装了char* ,管理这个字符串,是char*型的容器

特点:

- string内部封装了很多的成员方法:
    - 例如: 查找find, 拷贝copy, 删除delete, 替换 replae, 插入insert
- string管理char* 所分配的内存,不用担心复制越界和取值越界等,由类内部进行负责

# string构造函数

构造函数原型;

- string(); // 创建一个空的字符串,例如: string str;
    - string(const char* s); // 使用字符串s初始化
        - string(const string& str); // 使用一个string对象初始化另一个string对象
            - string(int n, char c); // 使用n 个字符c初始化

```c
int main() {
    // 构造string
    string str1(10, 'c');
    string str2;
    char ch[] = "hello world";
    string str3(ch);
    string str4 = "xinyan" ;
    string str(str4);
    cout << str << endl;
    return 0;
}

```

# string的赋值操作

给string字符串进行赋值

> string& poerator(const char* s); // char* 类型的字符串赋值给当前字符串
string& operator = (const string& s);  // 把字符串s赋给当前字符串
string& operator = (char c);   // 字符赋给当前的字符串
> 
> 
> string& assign(const char* s);   // 把字符串s赋给当前字符串
> string& assign(const char* s, int n);   // 把字符串s的前n个字符赋给当前字符串
> string& assign(const string& s);    // 把字符串s赋给当前字符串
> string& assign(int n, char c);      // 用n个字符c赋给当前字符串
> 
> string& assign(const string& str, size_t pos, size_t count); // 将字符串str从pos位置开始，赋值count个字符给当前字符串
> 

```c
// 字符串赋值
int main() {
    string str("zhangxinyan");
    char ch[] = "hello world";
// string& poerator = (const char* s); // char* 类型的字符串赋值给当前字符串
    string str1;
    str1  = ch;
    cout << str1 << endl;    // hello world

// string& operator = (const string& s);  // 把字符串s赋给当前字符串
    string str2;
    str2 = str;
    cout << str2 << endl;  // zhangxinyan

// string& operator = (char c);   // 字符赋给当前的字符串
    string str3;
    str3 = 'c';
    cout << str3 << endl;  // c

// string& assign(const char* s);   // 把字符串s赋给当前字符串
    string str4;
    str4.assign(str);
    cout << str4 << endl;  // zhangxinyan

// string& assign(const char* s, int n);   // 把字符串s的前n个字符赋给当前字符串
    string str5;
    str5.assign(ch, 8, 10);
    cout << str5 << endl;  // hello wo

// string& assign(const string& s);    // 把字符串s赋给当前字符串
    string str6;
    str6.assign(str);
    cout << str6 << endl;  // zhangixnyan

// string& assign(int n, char c);      // 用n个字符c赋给当前字符串
    string str7;
    str7.assign(10, 'l');
    cout << str7 << endl;

// string& assign(const string& str, size_t pos, size_t count); // 将字符串str从pos位置开始，赋值count个字符给当前字符串
    string str8;
    str8.assign(str, 5, 3);
    cout << str8 << endl;   // xin
    return 0;
}

```

# 字符串拼接

- string& operator+=(const char* str);
- string& operator+=(const char c);
- string& operator+=(const string& str);
- string& append(const char* s);	// 把字符串s连接到当前字符串结尾
- strinf& append(consst char* s, int n); // 把字符串s的前n个字符连接到当前字符串的结尾
- string& append(const string& s);	//同operator+=(const string& str)
- string& append(const string& s, int pos, int n); // 把字符串s中从pos位置开始的n个字符连接到字符串结尾

```c
// 字符串赋值
int main() {
    string str1("zhangxinyan ");
    char ch[] = "hello world ";
    string str2 = "zhang ";
    // string& operator+=(const char* str);
    // str2 += ch;
    // cout << str2 << endl; // zhang hello world

    // string& operator+=(const char c);
    // str2 += 'c';
    // cout << str2 << endl; //zhang c

    // string& operator+=(const string& str);
    // str2 += str1;
    // cout << str2 << endl; // zhang zhangxinyan

    // string& append(const char* s);  		// 把字符串s连接到当前字符串结尾
    // str2.append(ch);
    // cout << str2 << endl; //zhang hello world

    // strinf& append(consst char* s, int n);  // 把字符串s的前n个字符连接到当前字符串的结尾
    // str2.append(ch, 7);
    // cout << str2 << endl; //zhang hello w

    // string& append(const string& s); 		//同operator+=(const string& str)
    // str2.append(str1);
    // cout << str2 << endl; // zhang zhangxinyan

    // string& append(const string& s, int pos, int n);   // 把字符串s中从pos位置开始的n个字符连接到字符串结尾
    str2.append(str1, 3, 7);
    cout << str2 << endl;  // zhang ngxinya

    return 0;
}

```

# 字符串查找

---

- 查找指定字符串是否存在
- 替换： 在指定的位置替换字符串

find是从左往右查找

rfind是从右往左查找

# 字符串替换

> striing& replace(int pos, int n, const string& str);   替换从pos位置开始n个字符为strstring& replace(int pos, int n, const char* s);   替换从pos开始的n个字符为字符串s
> 

```c
// 字符串查找和替换
int main() {
    string str = "hello world";
    string str1 = "I love code";
    char ch[] = "xuptggg";
    str1.replace(3, 5,str);
    cout << str1 << endl;  // I lhello worldode
    str1.replace(4, 4, ch);
    cout << str1 << endl;  // I lhxuptggg worldode
    return 0;
}

```

# 字符串比较

---

比较方式

- *字符串比较是按照字符的ASCLL码进行比较的*

=  返回 0

\>  返回 1

< 返回 -1

函数原型:

> int compare(const string& s) const;  与字符串s比较
> 
> 
> int conpare(const char* s) const;   与字符串s比较
> 

```c
int main() {
    string str1 = "hello";
    string str2 = "xello";
    char ch[] = "xupt";
    int n =  str1.compare(str2);
    int m = str1.compare(ch);
    cout << m << endl;  // -1
    cout << n << endl;  // -1
    return 0;
}
```

# 字符串的存取

获取字符有两种方法

- `char& operator[](int n)` 通过的方式获取
- `char& at(int n)` 通过at 的方式获取字符

方法一   通过[]的方式获取

```c
void test01() {
    string str("helle");
    for (int i = 0; i < str.size(); i++) {
        cout << str[i] << " ";
    }
    cout << endl;
}

```

方法二  通过at的方式获取

```c
void test02() {
    string str("helle");
    for (int i = 0; i < str.size(); i++) {
        cout << str.at(i) << " ";
    }
    cout << endl;
}

```

# string插入和删除

---

对string字符串进行插入和删除字符串

函数原型:

- strign& insert (int pos, const char* s); 插入字符串
    
    string& insert (int pos, const string& str);  插入字符串
    
    string& insert (int  pos, int n, char c); 在指定位置插入n个字符
    
    // 1. 删除单个字符
    s.erase(pos);  // 从pos开始删除一个字符
    
    // 2. 删除从pos开始的多个字符
    s.erase(pos, count);  // 从pos开始删除count个字符
    
    // 3. 使用迭代器
    s.erase(it);  // 删除迭代器指向的字符
    
    // 4. 删除迭代器范围的字符
    s.erase(first, last);  // 删除[first, last)区间的字符
    

```c
int main() {
    string str = "hello world";
    str.erase(3);
    cout << str << endl;  // hel
    return 0;
}

```

# string 子串的截取

**从字符串中获取想要的子串**

函数原型:

> string substr(int pos = 0; int n = npos) const;   返回由pos开始的n个字符组成的字符串 当不传入 n 参数时，n 取默认值 string::npos，表示从 pos 开始截取到字符串末尾的所有字符。
> 

```c
int main() {
    string str = "hello world";
    string str1;
    str1 = str.substr(3);
    cout << str1 << endl; // ld world
    return 0;
}

```