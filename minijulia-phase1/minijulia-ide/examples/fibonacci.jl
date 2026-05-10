# Fibonacci — iterative

function fib(n)
    if n <= 0
        return 0
    end
    if n == 1
        return 1
    end
    a = 0
    b = 1
    i = 2
    while i <= n
        temp = a + b
        a = b
        b = temp
        i = i + 1
    end
    return b
end

# In 20 số Fibonacci đầu tiên
println("20 số Fibonacci đầu tiên:")
i = 0
while i < 20
    print(string(fib(i)))
    if i < 19
        print(", ")
    end
    i = i + 1
end
println("")
println("")

# Lưu vào mảng
fibs = []
i = 0
while i <= 15
    push!(fibs, fib(i))
    i = i + 1
end
println("Mảng fib(0..15): ")
j = 1
while j <= length(fibs)
    println("  fib(" * string(j - 1) * ") = " * string(fibs[j]))
    j = j + 1
end

# Tìm số Fibonacci đầu tiên lớn hơn 1000
println("")
n = 0
while fib(n) <= 1000
    n = n + 1
end
println("Số Fibonacci đầu tiên > 1000: fib(" * string(n) * ") = " * string(fib(n)))
