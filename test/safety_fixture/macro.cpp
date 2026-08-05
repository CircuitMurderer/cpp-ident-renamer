class MacroUse {
public:
    int Read() const;

private:
    int value;
};

#define CURRENT_VALUE value

int MacroUse::Read() const {
    return CURRENT_VALUE;
}
