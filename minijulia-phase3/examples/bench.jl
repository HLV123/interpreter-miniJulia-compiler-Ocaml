# Benchmark: Fibonacci(35) — tính nhiều lần để thấy speedup VM vs interpreter

function fib(n)
    if n <= 1
        return n
    end
    a = 0
    b = 1
    k = 2
    while k <= n
        t = a + b
        a = b
        b = t
        k = k + 1
    end
    return b
end

# Tính fib cho nhiều giá trị
total = 0
i = 0
while i <= 30
    total = total + fib(i)
    i = i + 1
end
println("Sum fib(0..30) = " * string(total))

# Sieve of Eratosthenes
function sieve(limit)
    is_prime = zeros(limit + 1)
    i = 0
    while i <= limit
        is_prime[i + 1] = 1
        i = i + 1
    end
    is_prime[1] = 0
    p = 2
    while p * p <= limit
        if is_prime[p] == 1
            j = p * p
            while j <= limit
                is_prime[j] = 0
                j = j + p
            end
        end
        p = p + 1
    end
    count = 0
    k = 2
    while k <= limit
        if is_prime[k] == 1
            count = count + 1
        end
        k = k + 1
    end
    return count
end

println("Primes up to 1000: " * string(sieve(1000)))
println("Primes up to 5000: " * string(sieve(5000)))
