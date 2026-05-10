# Demo: Kiểu dữ liệu, biến, toán tử

println("=== Kiểu dữ liệu ===")
x = 42
f = 3.14
s = "hello"
b = true
n = nothing

println("Int:     " * string(x))
println("Float:   " * string(f))
println("String:  " * s)
println("Bool:    " * string(b))
println("Nothing: " * string(n))

println("")
println("=== Toán tử số học ===")
a = 10
b2 = 3
println(string(a) * " + " * string(b2) * " = " * string(a + b2))
println(string(a) * " - " * string(b2) * " = " * string(a - b2))
println(string(a) * " * " * string(b2) * " = " * string(a * b2))
println(string(a) * " / " * string(b2) * " = " * string(a / b2))
println(string(a) * " % " * string(b2) * " = " * string(mod(a, b2)))
println(string(a) * " ^ " * string(b2) * " = " * string(a ^ b2))

println("")
println("=== Chuỗi ===")
s1 = "Xin chào"
s2 = " thế giới"
println(s1 * s2)
println("Độ dài: " * string(length(s1)))
println("Hoa: " * uppercase(s1))
println("Thường: " * lowercase(s1))

println("")
println("=== Mảng ===")
arr = [10, 20, 30, 40, 50]
println("Mảng: " * string(arr))
println("arr[1] = " * string(arr[1]))
println("arr[3] = " * string(arr[3]))
println("Độ dài: " * string(length(arr)))

push!(arr, 60)
println("Sau push!(60): " * string(arr))

arr[2] = 99
println("Sau arr[2]=99: " * string(arr))

println("")
println("=== Điều kiện ===")
score = 85
if score >= 90
    println("Xuất sắc")
elseif score >= 80
    println("Giỏi")
elseif score >= 70
    println("Khá")
else
    println("Trung bình")
end

println("")
println("=== Vòng lặp while ===")
i = 1
sum = 0
while i <= 10
    sum = sum + i
    i = i + 1
end
println("Tổng 1..10 = " * string(sum))

println("")
println("=== Vòng lặp for ===")
total = 0
for n = 1:5
    total = total + n
    print(string(n))
    if n < 5
        print(" + ")
    end
end
println(" = " * string(total))

println("")
println("=== Hàm ===")
function greet(name)
    return "Xin chào, " * name * "!"
end

function power(base, exp)
    result = 1
    i = 1
    while i <= exp
        result = result * base
        i = i + 1
    end
    return result
end

println(greet("MiniJulia"))
println("2^10 = " * string(power(2, 10)))

println("")
println("=== Toán học ===")
println("sqrt(144) = " * string(sqrt(144)))
println("abs(-42)  = " * string(abs(-42)))
println("floor(3.7)= " * string(floor(3.7)))
println("ceil(3.2) = " * string(ceil(3.2)))
println("max(5,9)  = " * string(max(5, 9)))
println("min(5,9)  = " * string(min(5, 9)))
