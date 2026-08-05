#pragma once

#include <stddef.h>

namespace project {

struct Request {};
struct String {};
using Name = char*;

class Processor {
public:
    int GetSize() const;
    static bool IsReady();

private:
    int numberOfSlice;
    String keywordName;
    Request currentRequest;
    char* name;
    const char* m_psTitle;
    Name aliasName;
    static double AverageValue;
};

int ComputeValue();

} // namespace project
