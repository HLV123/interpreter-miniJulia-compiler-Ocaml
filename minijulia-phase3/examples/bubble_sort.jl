# Bubble Sort — sắp xếp mảng

function bubble_sort(arr)
    n = length(arr)
    i = 1
    while i <= n
        j = 1
        while j <= n - i
            if arr[j] > arr[j + 1]
                # swap
                temp = arr[j]
                arr[j] = arr[j + 1]
                arr[j + 1] = temp
            end
            j = j + 1
        end
        i = i + 1
    end
    return arr
end

function print_array(arr)
    print("[")
    i = 1
    while i <= length(arr)
        print(string(arr[i]))
        if i < length(arr)
            print(", ")
        end
        i = i + 1
    end
    println("]")
end

# Test 1: mảng số ngẫu nhiên
arr1 = [64, 34, 25, 12, 22, 11, 90]
print("Trước khi sắp xếp: ")
print_array(arr1)
bubble_sort(arr1)
print("Sau khi sắp xếp:   ")
print_array(arr1)
println("")

# Test 2: mảng đã sắp xếp ngược
arr2 = [9, 8, 7, 6, 5, 4, 3, 2, 1]
print("Trước: ")
print_array(arr2)
bubble_sort(arr2)
print("Sau:   ")
print_array(arr2)
println("")

# Test 3: mảng 1 phần tử
arr3 = [42]
print("Mảng 1 phần tử: ")
print_array(arr3)
bubble_sort(arr3)
print("Sau sort:        ")
print_array(arr3)
