# Fibonacci — iterative (Phase 2: Bytecode VM)

function fib(n)
    if n <= 1
        return n
    end
    fa = 0
    fb = 1
    fk = 2
    while fk <= n
        ft = fa + fb
        fa = fb
        fb = ft
        fk = fk + 1
    end
    return fb
end

println("20 so Fibonacci dau tien:")
cnt = 0
while cnt < 20
    println("fib(" * string(cnt) * ") = " * string(fib(cnt)))
    cnt = cnt + 1
end

println("")
println("Mang fib(0..10):")
fibs = []
jj = 0
while jj <= 10
    push!(fibs, fib(jj))
    jj = jj + 1
end
mm = 1
while mm <= length(fibs)
    println("  fib(" * string(mm - 1) * ") = " * string(fibs[mm]))
    mm = mm + 1
end

println("")
nn = 0
while fib(nn) <= 1000
    nn = nn + 1
end
println("Fib dau tien > 1000: fib(" * string(nn) * ") = " * string(fib(nn)))
