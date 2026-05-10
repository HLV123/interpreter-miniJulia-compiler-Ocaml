# Kiểm tra số nguyên tố
function is_prime(n)
    if n < 2
        return false
    end
    if n == 2
        return true
    end
    if mod(n, 2) == 0
        return false
    end
    i = 3
    while i * i <= n
        if mod(n, i) == 0
            return false
        end
        i = i + 2
    end
    return true
end

# In các số nguyên tố từ 1 đến 50
println("Số nguyên tố từ 1 đến 50:")
primes = []
for n = 1:50
    if is_prime(n)
        push!(primes, n)
    end
end

# In kết quả
i = 1
while i <= length(primes)
    print(string(primes[i]))
    if i < length(primes)
        print(", ")
    end
    i = i + 1
end
println("")

println("Tổng cộng: " * string(length(primes)) * " số nguyên tố")

# Kiểm tra một số cụ thể
num = 97
if is_prime(num)
    println(string(num) * " là số nguyên tố")
else
    println(string(num) * " không phải số nguyên tố")
end
