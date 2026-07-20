module UnsafeLoader
  def self.load(expression)
    eval(expression)
  end
end
